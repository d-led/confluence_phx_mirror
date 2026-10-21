defmodule ConfluencePhxMirrorWeb.Plugs.AutoAdmin do
  @moduledoc """
  Assumes an administrator in development and test (`MIRROR_AUTO_ADMIN`).

  The mirror is read-only, so the assumed admin only unlocks the admin screens
  and subscriptions — there is nothing destructive to protect.
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
