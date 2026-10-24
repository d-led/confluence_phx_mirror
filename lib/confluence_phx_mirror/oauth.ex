defmodule ConfluencePhxMirror.OAuth do
  @moduledoc """
  The authorization server the MCP endpoint points at: just enough OAuth 2.1 for
  a remote MCP client, and no more.

  A remote MCP client that meets an unauthenticated endpoint is expected to
  discover an authorization server, register itself, send the reader's browser
  to an authorization page, and exchange the returned code for an access token.
  That is the whole flow implemented here — authorization code, PKCE (S256),
  public clients and dynamic client registration — because it is the flow that
  makes the endpoint usable without anyone pasting a token.

  Nothing is stored, which is what keeps the mirror stateless across replicas:
  a registration, an authorization code and an access token are each a
  `Phoenix.Token` — signed, self-describing and short-lived:

    * a **client id** carries its redirect URIs and lasts a year;
    * an **authorization code** carries the reader, the client, the redirect URI
      and the PKCE challenge, and lasts a minute;
    * an **access token** carries the reader and the client, and lasts twelve
      hours.

  What is *not* stored is as much a design decision as what is: the mirror is
  read-only, so a token grants reading and nothing else, and authorization is
  decided per request from the database exactly as it is for a session. Revoking
  is therefore about the account, not the token: disabling a reader takes effect
  on their next call, and rotating `SECRET_KEY_BASE` invalidates every issued
  token at once. A code replayed inside its minute mints a second token for the
  same reader and client; PKCE is what stops anybody else from using it.

  The identity behind the browser step comes from the mirror's own session or
  from the reverse proxy (`X-Forwarded-Email`), so `oauth2-proxy` keeps its job —
  logging the human in — and the mirror no longer needs it to hand out tokens.
  """

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirrorWeb.Endpoint

  @client_salt "mcp client registration"
  @code_salt "mcp authorization code"
  @access_salt "mcp access token"

  @client_max_age 365 * 24 * 60 * 60
  @code_max_age 60
  @access_max_age 12 * 60 * 60

  @scopes ~w(read)

  @doc "The scope a token grants. The mirror is read-only, so there is one."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "The resource identifier the tokens are issued for."
  @spec resource() :: String.t()
  def resource, do: Endpoint.url() <> "/api/mcp"

  # ---------------------------------------------------------------------------
  # Client registration
  # ---------------------------------------------------------------------------

  @doc """
  Registers a public client from a dynamic-client-registration request.

  Returns the metadata a client needs, and the `client_id` it will send back
  with the authorization request. The id is a signed token, so validation needs
  no table and works on every replica.
  """
  @spec register(map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def register(params) do
    with {:ok, uris} <- redirect_uris(params["redirect_uris"]),
         :ok <- public_client(params),
         :ok <- authorization_code_grant(params) do
      name = client_name(params["client_name"])
      issued_at = System.system_time(:second)

      client_id =
        Phoenix.Token.sign(Endpoint, @client_salt, %{
          "redirect_uris" => uris,
          "client_name" => name,
          "issued_at" => issued_at
        })

      {:ok,
       %{
         "client_id" => client_id,
         "client_id_issued_at" => issued_at,
         "client_name" => name,
         "redirect_uris" => uris,
         "grant_types" => ["authorization_code"],
         "response_types" => ["code"],
         "token_endpoint_auth_method" => "none"
       }}
    end
  end

  @doc "The client a `client_id` names, if the mirror signed it and it is fresh."
  @spec client(String.t()) :: {:ok, map()} | :error
  def client(client_id) when is_binary(client_id) do
    case Phoenix.Token.verify(Endpoint, @client_salt, client_id, max_age: @client_max_age) do
      {:ok, %{} = client} -> {:ok, client}
      _invalid -> :error
    end
  end

  def client(_client_id), do: :error

  defp redirect_uris([_ | _] = uris) when is_list(uris) do
    if Enum.all?(uris, &redirect_uri?/1) do
      {:ok, uris}
    else
      {:error, "invalid_redirect_uri", "Every redirect URI must be an absolute http(s) URL."}
    end
  end

  defp redirect_uris(_missing) do
    {:error, "invalid_redirect_uri", "`redirect_uris` must be a non-empty list."}
  end

  # A confidential client would need a secret store; an MCP client is a public
  # client with PKCE, and saying so is better than half-supporting secrets.
  defp public_client(%{"token_endpoint_auth_method" => method})
       when method not in [nil, "none"] do
    {:error, "invalid_client_metadata",
     "Only public clients (`token_endpoint_auth_method: none`)."}
  end

  defp public_client(_params), do: :ok

  defp authorization_code_grant(%{"grant_types" => types}) when is_list(types) do
    if "authorization_code" in types do
      :ok
    else
      {:error, "invalid_client_metadata", "Only `authorization_code` grants are supported."}
    end
  end

  defp authorization_code_grant(_params), do: :ok

  defp client_name(name) when is_binary(name) and name != "", do: String.slice(name, 0, 80)
  defp client_name(_missing), do: "An MCP client"

  defp redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, fragment: nil} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _not_an_absolute_http_url ->
        false
    end
  end

  defp redirect_uri?(_uri), do: false

  # ---------------------------------------------------------------------------
  # Authorization codes
  # ---------------------------------------------------------------------------

  @doc """
  The code handed back to the client's redirect URI.

  The unsigned fields a client sends back — the redirect URI, the PKCE
  challenge — travel inside the signed code, so the exchange compares what the
  client presents with what was actually authorized.
  """
  @spec authorization_code(User.t(), map()) :: String.t()
  def authorization_code(%User{} = user, attrs) do
    Phoenix.Token.sign(Endpoint, @code_salt, %{
      "sub" => user.id,
      "client_id" => attrs["client_id"],
      "redirect_uri" => attrs["redirect_uri"],
      "code_challenge" => attrs["code_challenge"],
      "resource" => attrs["resource"] || resource()
    })
  end

  @doc """
  Exchanges a code for an access token.

  Checks what OAuth requires a server to check: the code is fresh, it was issued
  to this client, the redirect URI is the one it was issued for, and the PKCE
  verifier hashes to the challenge the browser approved.
  """
  @spec exchange(map()) :: {:ok, String.t(), User.t()} | {:error, String.t(), String.t()}
  def exchange(params) do
    with {:ok, code} <- code(params["code"]),
         :ok <- issued_to(code, params),
         {:ok, user} <- reader(code["sub"]),
         :ok <- pkce(code, params) do
      {:ok, access_token(user, code["client_id"]), user}
    end
  end

  defp code(nil), do: {:error, "invalid_request", "`code` is required."}

  defp code(value) when is_binary(value) do
    case Phoenix.Token.verify(Endpoint, @code_salt, value, max_age: @code_max_age) do
      {:ok, %{} = code} ->
        {:ok, code}

      _expired_or_forged ->
        {:error, "invalid_grant", "The authorization code is invalid or expired."}
    end
  end

  defp issued_to(code, params) do
    cond do
      code["client_id"] != params["client_id"] ->
        {:error, "invalid_grant", "The code was issued to a different client."}

      code["redirect_uri"] != params["redirect_uri"] ->
        {:error, "invalid_grant", "The redirect URI does not match the one authorized."}

      true ->
        :ok
    end
  end

  defp reader(id) do
    case Accounts.get_user(id) do
      %User{} = user ->
        if User.disabled?(user),
          do: {:error, "invalid_grant", "The account is disabled."},
          else: {:ok, user}

      nil ->
        {:error, "invalid_grant", "The reader no longer exists."}
    end
  end

  defp pkce(code, params) do
    verifier = params["code_verifier"]

    cond do
      verifier in [nil, ""] ->
        {:error, "invalid_request", "`code_verifier` is required (PKCE)."}

      String.length(verifier) < 43 or String.length(verifier) > 128 ->
        {:error, "invalid_request", "`code_verifier` must be 43 to 128 characters."}

      challenge(verifier) == code["code_challenge"] ->
        :ok

      true ->
        {:error, "invalid_grant", "The code verifier does not match the challenge."}
    end
  end

  @doc "The S256 challenge a verifier hashes to."
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  # ---------------------------------------------------------------------------
  # Access tokens
  # ---------------------------------------------------------------------------

  @doc "An access token for a reader and the client they approved."
  @spec access_token(User.t(), String.t()) :: String.t()
  def access_token(%User{id: id}, client_id) do
    Phoenix.Token.sign(Endpoint, @access_salt, %{"sub" => id, "client_id" => client_id})
  end

  @doc """
  The reader an access token names, if it is fresh and their account is active.

  Cheap on purpose — an HMAC check and one row — because every MCP call pays for
  it, unlike the Argon2 verification an API token needs.
  """
  @spec user_from_access_token(String.t()) :: {:ok, User.t()} | {:error, atom()} | :error
  def user_from_access_token(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @access_salt, token, max_age: @access_max_age) do
      {:ok, %{"sub" => id}} -> active_reader(id)
      _invalid_or_expired -> :error
    end
  end

  def user_from_access_token(_token), do: :error

  defp active_reader(id) do
    case Accounts.get_user(id) do
      %User{} = user ->
        if User.disabled?(user), do: {:error, :account_disabled}, else: {:ok, user}

      nil ->
        :error
    end
  end

  @doc "How long an access token lasts, in seconds, for the metadata and the docs."
  @spec access_token_ttl() :: pos_integer()
  def access_token_ttl, do: @access_max_age
end
