defmodule ConfluencePhxMirrorWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer / Basic authentication for the read-only API.

  Accepts `Authorization: Bearer <token>` and, for Confluence-style clients,
  `Authorization: Basic base64(email:token)`. In development and test an
  administrator is assumed when no credentials are sent.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case identity(conn) do
      :none -> assume_or_reject(conn)
      {:ok, user} -> authenticate(conn, {:ok, user})
      {:error, reason} -> authenticate(conn, {:error, reason})
    end
  end

  @doc """
  Who the request's credentials name: `{:ok, user}`, `{:error, reason}`, or
  `:none` when it carries no credentials at all.

  Exposed because the MCP endpoint authenticates the same way (`McpAuth`) and
  must not grow a second, subtly different parser. Choosing what an absent
  credential means stays with each plug: the API assumes an administrator in
  development, MCP answers a challenge in a real deployment.
  """
  @spec identity(Plug.Conn.t()) ::
          {:ok, ConfluencePhxMirror.Accounts.User.t()} | {:error, atom()} | :none
  def identity(conn) do
    conn = fetch_query_params(conn)

    case credentials(conn) do
      {:bearer, token} -> authenticate(token)
      {:basic, email, token} -> Accounts.authenticate_basic(email, token)
      :none -> :none
    end
  end

  # An MCP client arrives with the access token the mirror's own authorization
  # server issued; everybody else arrives with an API token. The signed token is
  # tried first because verifying it is an HMAC, while the API token lookup is a
  # row plus an Argon2 check.
  defp authenticate(token) do
    case ConfluencePhxMirror.OAuth.user_from_access_token(token) do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
      :error -> Accounts.authenticate_api_token(token)
    end
  end

  defp authenticate(conn, {:ok, user}) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, Scope.for_user(user))
    |> assign(:api_token, true)
  end

  defp authenticate(conn, {:error, :account_disabled}) do
    conn
    |> send_error(403, "account_disabled", "This account is disabled.")
    |> halt()
  end

  defp authenticate(conn, {:error, reason}) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="confluence-mirror"))
    |> send_error(401, "invalid_token", "API token is invalid or expired (#{reason}).")
    |> halt()
  end

  defp assume_or_reject(conn) do
    if Application.get_env(:confluence_phx_mirror, :auto_admin, false) do
      user = Accounts.ensure_admin!()

      conn
      |> assign(:current_user, user)
      |> assign(:current_scope, Scope.for_user(user))
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="confluence-mirror"))
      |> send_error(401, "unauthorized", "Provide an API token in the Authorization header.")
      |> halt()
    end
  end

  defp credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        {:bearer, String.trim(token)}

      ["Basic " <> encoded | _] ->
        basic(encoded)

      _ ->
        :none
    end
  end

  # `email:token`, base64-encoded — Confluence's own client speaks HTTP basic.
  # A header that is not that shape carries no credentials at all.
  defp basic(encoded) do
    with {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         [email, token] <- String.split(decoded, ":", parts: 2) do
      {:basic, email, token}
    else
      _not_basic -> :none
    end
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: code, message: message}))
  end
end
