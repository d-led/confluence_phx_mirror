defmodule ConfluencePhxMirrorWeb.Plugs.RequireAdmin do
  @moduledoc "Restricts admin screens to administrators."

  import Plug.Conn
  import Phoenix.Controller

  alias ConfluencePhxMirror.Accounts.User

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %User{} = user ->
        if User.admin?(user) do
          conn
        else
          conn
          |> put_flash(:error, "Administrator access required.")
          |> redirect(to: "/")
          |> halt()
        end

      nil ->
        conn |> put_flash(:error, "Please sign in.") |> redirect(to: "/session") |> halt()
    end
  end
end
