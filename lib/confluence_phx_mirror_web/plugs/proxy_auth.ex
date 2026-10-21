defmodule ConfluencePhxMirrorWeb.Plugs.ProxyAuth do
  @moduledoc """
  Provisions reader accounts from the reverse proxy's identity header.

  Behind an OAuth2 proxy the proxy authenticates the reader and forwards
  `X-Forwarded-Email` (name configurable). With `CM_PROXY_AUTH=true` the mirror
  trusts that header: an unknown address becomes an account on first sight, so
  there is no sign-up step and no account form. Roles and groups stay local.

  Trusting a header means the endpoint must not be reachable except through the
  proxy; that is why the plug is off unless explicitly enabled. Without a
  header the request keeps whatever session it already had, so magic links
  still work next to a proxy.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    if enabled?() do
      case presented(conn, config(:proxy_auth_header, "x-forwarded-email")) do
        nil -> conn
        email -> sign_in(conn, email)
      end
    else
      conn
    end
  end

  defp sign_in(conn, email) do
    attrs =
      case presented(conn, config(:proxy_auth_name_header, "x-forwarded-user")) do
        nil -> %{}
        name -> %{display_name: name}
      end

    case Accounts.ensure_user(email, attrs) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> assign(:current_user, user)
        |> assign(:current_scope, Scope.for_user(user))

      {:error, _changeset} ->
        conn
        |> send_resp(403, "Access denied")
        |> halt()
    end
  end

  defp presented(conn, header) do
    case conn |> get_req_header(header) |> List.first() do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  defp enabled?, do: config(:proxy_auth, false)

  defp config(key, default), do: Application.get_env(:confluence_phx_mirror, key, default)
end
