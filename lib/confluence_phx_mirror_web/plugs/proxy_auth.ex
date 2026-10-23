defmodule ConfluencePhxMirrorWeb.Plugs.ProxyAuth do
  @moduledoc """
  Provisions reader accounts from the reverse proxy's identity header.

  Behind an OAuth2 proxy the proxy authenticates the reader and forwards
  `X-Forwarded-Email` (name configurable). With `CM_PROXY_AUTH=true` the mirror
  trusts that header: an admitted address becomes an account on first sight, so
  there is no sign-up step and no account form. Roles and groups stay local.

  The proxy answers "who is this?", not "should they be here?" — an Atlassian
  organisation is usually wider than the site being mirrored. So the mirror
  admits an identity only when it has a reason to: a mirror administrator, or
  somebody the sync has seen on the mirrored site (a member of a mentioned
  group, or a user named in a space permission or page restriction, see
  `ConfluencePhxMirror.Mirror.identity_known?/1`). Anyone else gets a 403 page
  and no account. `CM_PROXY_AUTH_MEMBERS_ONLY=false` restores the older
  behaviour, where the proxy's word was enough.

  Trusting a header means the endpoint must not be reachable except through the
  proxy; that is why the plug is off unless explicitly enabled. Without a
  header the request keeps whatever session it already had, so magic links
  still work next to a proxy.
  """

  import Plug.Conn

  import Phoenix.Controller, only: [put_view: 2, render: 3]

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Admins, Scope, User}
  alias ConfluencePhxMirror.Mirror

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
    if admitted?(email) do
      provision(conn, email)
    else
      refuse(conn)
    end
  end

  defp provision(conn, email) do
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
        refuse(conn)
    end
  end

  # A disabled account is refused whatever else is true of it: it is the
  # strongest statement an operator can make about a reader. Otherwise an
  # administrator, and everybody else only when the sync can vouch for them —
  # the account is looked up, never created, before the decision.
  defp admitted?(email) do
    user = Accounts.get_user_by_email(email)

    not disabled?(user) and
      (not members_only?() or Admins.seeded?(email) or known?(user, email))
  end

  defp disabled?(%User{} = user), do: User.disabled?(user)
  defp disabled?(nil), do: false

  defp known?(%User{} = user, _email) do
    Admins.admin?(user) or Mirror.identity_known?(User.identity_keys(user))
  end

  defp known?(nil, email), do: Mirror.identity_known?([email])

  defp refuse(conn) do
    conn
    |> put_status(403)
    |> put_view(ConfluencePhxMirrorWeb.ErrorHTML)
    |> render(:"403", message: nil)
    |> halt()
  end

  defp presented(conn, header) do
    case conn |> get_req_header(header) |> List.first() do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  defp enabled?, do: config(:proxy_auth, false)

  defp members_only?, do: config(:proxy_auth_members_only, true)

  defp config(key, default), do: Application.get_env(:confluence_phx_mirror, key, default)
end
