defmodule ConfluencePhxMirrorWeb.Plugs.AutoAdmin do
  @moduledoc """
  Assumes an administrator in development and test (`MIRROR_AUTO_ADMIN`).

  The reader is the mirror; the admin screens are where it can be changed or
  deleted. Those screens do have destructive actions — emptying the trash
  removes content for good, and accounts, settings and webhooks are writable —
  so this plug is a development convenience, not a deployment setting: a
  production release that mirrors a real site refuses to start with it enabled
  (`ConfluencePhxMirror.Config.IdentityGuard`). In development and the test
  suite it is what lets a browser open `/admin` without a sign-in.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    if enabled?() and is_nil(conn.assigns[:current_user]) do
      user = Accounts.ensure_admin!()

      conn
      |> put_session(:user_id, user.id)
      |> assign(:current_user, user)
      |> assign(:current_scope, Scope.for_user(user))
    else
      conn
    end
  end

  defp enabled?, do: Application.get_env(:confluence_phx_mirror, :auto_admin, false)
end
