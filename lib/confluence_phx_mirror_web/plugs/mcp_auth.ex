defmodule ConfluencePhxMirrorWeb.Plugs.McpAuth do
  @moduledoc """
  Authentication for the MCP endpoint.

  The credentials are the JSON API's, by construction: `ApiAuth.identity/1`
  answers who the request names, so a bearer token and `base64(email:token)`
  behave here exactly as they do on `/api/v1`. On top of that, an identity the
  reverse proxy established — the session it authenticated and wrote into
  `X-Forwarded-Email`, read by `ProxyAuth` earlier in the pipeline — is
  accepted, because a reader already signed in to the mirror should not have to
  mint a token to use its MCP server.

  With no credentials and no established identity, a demo mirror (the
  `auto_admin` setting development and test run with) answers as an
  administrator: the endpoint is usable out of the box, and the deployment that
  ships it to the internet sets `auto_admin` to false and gets a 401 challenge.

  A 401 here is also the browser capability hint the MCP authorization
  specification expects: `WWW-Authenticate: Bearer realm="confluence-mirror"`
  names what to send. The mirror does not run an OAuth authorization server —
  oauth2-proxy is a client of an identity provider, not a token issuer — so the
  token is either a reader's API token or nothing.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Scope, User}
  alias ConfluencePhxMirrorWeb.Plugs.ApiAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    case ApiAuth.identity(conn) do
      {:ok, user} ->
        accept(conn, user)

      :none ->
        established_or_demo(conn)

      {:error, :account_disabled} ->
        refuse(conn, 403, "account_disabled", "This account is disabled.")

      {:error, _invalid} ->
        challenge(conn)
    end
  end

  # `FetchCurrentUser` and `ProxyAuth` run before this plug. A reader either of
  # them resolved already carries a scope, computed once, with their groups and
  # administrator status; recomputing it here would ask the database twice.
  defp established_or_demo(conn) do
    case conn.assigns do
      %{current_user: %User{}} -> conn
      _anonymous -> demo_or_challenge(conn)
    end
  end

  defp demo_or_challenge(conn) do
    if Application.get_env(:confluence_phx_mirror, :auto_admin, false) do
      accept(conn, Accounts.ensure_admin!())
    else
      challenge(conn)
    end
  end

  defp accept(conn, user) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, Scope.for_user(user))
  end

  defp challenge(conn) do
    # RFC 9728: the challenge names where to read the authorization metadata, so
    # a client starts the OAuth flow by itself instead of asking for a token.
    metadata = ConfluencePhxMirrorWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource"

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer realm="confluence-mirror", resource_metadata="#{metadata}")
    )
    |> refuse(
      401,
      "unauthorized",
      "Authorize this client against the mirror, or send an API token."
    )
  end

  defp refuse(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{"error" => code, "message" => message}))
    |> halt()
  end
end
