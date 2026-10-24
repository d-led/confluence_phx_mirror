defmodule ConfluencePhxMirrorWeb.Plugs.ProxyAuth do
  @moduledoc """
  Provisions reader accounts from the reverse proxy's identity header.

  Behind an OAuth2 proxy the proxy authenticates the reader and forwards
  `X-Forwarded-Email` (name configurable). With `CM_PROXY_AUTH=true` the mirror
  trusts that header: an admitted address becomes an account on first sight, so
  there is no sign-up step and no account form. Roles and groups stay local.

  The proxy answers "who is this?", not "should they be here?". That second
  question belongs to `ConfluencePhxMirror.Accounts.UserPolicy`: the plug builds
  the identity the proxy presented — the address, and the groups it asserts when
  a group header is configured — and asks the deployment's policy. An identity
  the policy refuses gets a 403 page and no account.

  A disabled account is refused here, before the policy is asked: switching an
  account off is the strongest statement an operator can make about a reader,
  and no policy should be able to undo it.

  Trusting a header means the endpoint must not be reachable except through the
  proxy; that is why the plug is off unless explicitly enabled. Without a
  header the request keeps whatever session it already had, so magic links
  still work next to a proxy.
  """

  import Plug.Conn

  import Phoenix.Controller, only: [put_view: 2, render: 3]

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Scope, User, UserPolicy}

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
    if admitted?(conn, email) do
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
        user = signed_in(conn, user)

        conn
        |> put_session(:user_id, user.id)
        |> assign(:current_user, user)
        |> assign(:current_scope, Scope.for_user(user))

      {:error, _changeset} ->
        refuse(conn)
    end
  end

  # A proxy cookie is one visit, so every request in it is the same sign-in.
  # "Last seen" and the log entry are about visits, and a request that already
  # carried this reader is not one.
  #
  # A client that keeps no cookie at all — a scripted reader, a load test that
  # sends the header — would otherwise look new on every request and write a log
  # entry per page. Half an hour is the finest a "last seen" needs to be, and it
  # bounds what one such client can add to the log.
  @visit_seconds 1_800

  defp signed_in(conn, user) do
    if same_session?(conn, user) or seen_recently?(user) do
      user
    else
      {:ok, user} = Accounts.record_sign_in(user, "proxy")
      user
    end
  end

  defp same_session?(conn, user), do: get_session(conn, :user_id) == user.id

  defp seen_recently?(%User{last_sign_in_at: nil}), do: false

  defp seen_recently?(%User{last_sign_in_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) < @visit_seconds
  end

  defp admitted?(conn, email) do
    user = Accounts.get_user_by_email(email)

    not disabled?(user) and
      UserPolicy.allows?(
        %{
          email: email,
          account_id: user && user.confluence_account_id,
          groups: asserted_groups(conn),
          user: user
        },
        :proxy
      )
  end

  defp disabled?(%User{} = user), do: User.disabled?(user)
  defp disabled?(nil), do: false

  # Groups an identity provider asserts, when the deployment says which header
  # carries them. The mirror checks them against its own membership mirror and
  # nothing else — see `ConfluencePhxMirror.Mirror.members_of_asserted_groups?/2`.
  defp asserted_groups(conn) do
    case config(:proxy_auth_groups_header, nil) do
      nil ->
        []

      header ->
        conn
        |> get_req_header(header)
        |> Enum.flat_map(&String.split(&1, [",", ";"], trim: true))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

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

  defp config(key, default), do: Application.get_env(:confluence_phx_mirror, key, default)
end
