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
    conn = fetch_query_params(conn)

    case credentials(conn) do
      {:bearer, token} -> authenticate(conn, Accounts.authenticate_api_token(token))
      {:basic, email, token} -> authenticate(conn, Accounts.authenticate_basic(email, token))
      :none -> assume_or_reject(conn)
    end
  end

  defp authenticate(conn, {:ok, user}) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, Scope.for_user(user))
    |> assign(:api_token, true)
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
        case Base.decode64(String.trim(encoded)) do
          {:ok, decoded} ->
            case String.split(decoded, ":", parts: 2) do
              [email, token] -> {:basic, email, token}
              _ -> :none
            end

          :error ->
            :none
        end

      _ ->
        :none
    end
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: code, message: message}))
  end
end
