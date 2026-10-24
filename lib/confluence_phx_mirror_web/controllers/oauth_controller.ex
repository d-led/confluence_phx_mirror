defmodule ConfluencePhxMirrorWeb.OAuthController do
  @moduledoc """
  The interactive half of the MCP authorization server: registration, the
  consent page, and the code exchange.

  The consent page is the only step a human sees. It runs in the browser
  pipeline, so the reader is whoever the reverse proxy or the mirror's own
  session signed in — the same identity every other page uses — and it asks one
  question before a client may read on their behalf. Approving mints a code for
  that reader alone; the code carries the pending request, so the exchange needs
  no state and works on any replica.

  Registration and the token endpoint are machine-to-machine: no session, no
  cookie, JSON in and out, and no proxy identity required.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.OAuth

  # Everything the consent form has to hand back unchanged, so the approval is
  # about exactly the request the client made.
  @consent_keys ~w(client_id redirect_uri state code_challenge code_challenge_method response_type resource scope)

  @doc "Dynamic client registration (RFC 7591)."
  def register(conn, params) do
    case OAuth.register(params) do
      {:ok, client} -> conn |> put_status(201) |> json(client)
      {:error, error, message} -> fail(conn, 400, error, message)
    end
  end

  @doc "The token endpoint: an authorization code becomes an access token."
  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    case OAuth.exchange(params) do
      {:ok, token, user} ->
        json(conn, %{
          "access_token" => token,
          "token_type" => "Bearer",
          "expires_in" => OAuth.access_token_ttl(),
          "scope" => Enum.join(OAuth.scopes(), " "),
          "sub" => user.email
        })

      {:error, error, message} ->
        fail(conn, 400, error, message)
    end
  end

  def token(conn, _params) do
    fail(conn, 400, "unsupported_grant_type", "Only `authorization_code` is supported.")
  end

  @doc "The consent page: who is asking to read what, as whom."
  def authorize(conn, params) do
    with :ok <- signed_in(conn),
         {:ok, request} <- authorize_request(params) do
      render(conn, :authorize,
        form: Phoenix.Component.to_form(%{}),
        client_name: request["client_name"],
        email: conn.assigns.current_user.email,
        mirror_name: ConfluencePhxMirror.Sites.name(),
        request:
          @consent_keys
          |> Enum.reject(&(request[&1] in [nil, ""]))
          |> Map.new(&{&1, request[&1]})
      )
    else
      {:error, :signed_out} -> redirect(conn, to: "/session")
      {:error, :invalid_request, message} -> refuse(conn, message)
    end
  end

  @doc "The reader's answer; approving redirects back with a code."
  def decide(conn, %{"decision" => decision} = params) do
    with :ok <- signed_in(conn),
         {:ok, request} <- authorize_request(params) do
      redirect(conn, external: back_to_client(conn.assigns.current_user, request, decision))
    else
      {:error, :signed_out} -> redirect(conn, to: "/session")
      {:error, :invalid_request, message} -> refuse(conn, message)
    end
  end

  def decide(conn, params), do: decide(conn, Map.put(params, "decision", "deny"))

  # ---------------------------------------------------------------------------
  # The request, checked before anything is rendered or redirected
  # ---------------------------------------------------------------------------

  defp authorize_request(params) do
    with :ok <- code_response(params),
         {:ok, client} <- known_client(params),
         :ok <- registered_redirect(client, params),
         :ok <- pkce(params) do
      {:ok,
       params
       |> Map.take(@consent_keys)
       |> Map.put("client_name", client["client_name"])}
    end
  end

  defp code_response(%{"response_type" => "code"}), do: :ok
  defp code_response(_params), do: invalid("`response_type=code` is required.")

  defp known_client(params) do
    case OAuth.client(params["client_id"]) do
      {:ok, client} -> {:ok, client}
      :error -> invalid("This client is not registered with the mirror.")
    end
  end

  defp registered_redirect(client, params) do
    if params["redirect_uri"] in client["redirect_uris"] do
      :ok
    else
      invalid("`redirect_uri` is not one this client registered.")
    end
  end

  defp pkce(%{"code_challenge" => challenge, "code_challenge_method" => "S256"})
       when is_binary(challenge) and challenge != "",
       do: :ok

  defp pkce(_params), do: invalid("PKCE with `code_challenge_method=S256` is required.")

  defp invalid(message), do: {:error, :invalid_request, message}

  # ---------------------------------------------------------------------------
  # Results
  # ---------------------------------------------------------------------------

  defp back_to_client(user, request, decision) when decision in ["approve", "allow"] do
    code = OAuth.authorization_code(user, request)
    callback(request["redirect_uri"], %{"code" => code, "state" => request["state"]})
  end

  # Anything that is not an approval is a refusal; a client that gets it wrong
  # gets no access, which is the safe direction.
  defp back_to_client(_user, request, _decision) do
    callback(request["redirect_uri"], %{"error" => "access_denied", "state" => request["state"]})
  end

  defp callback(redirect_uri, params) do
    uri = URI.parse(redirect_uri)
    query = (uri.query && URI.query_decoder(uri.query) |> Map.new()) || %{}
    query = Map.merge(query, Map.reject(params, fn {_key, value} -> is_nil(value) end))
    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp signed_in(%{assigns: %{current_user: %{} = _user}}), do: :ok
  defp signed_in(_conn), do: {:error, :signed_out}

  defp refuse(conn, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, message <> "\n")
  end

  defp fail(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => error, "error_description" => message})
  end
end
