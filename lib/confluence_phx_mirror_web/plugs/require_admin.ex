defmodule ConfluencePhxMirrorWeb.Plugs.RequireAdmin do
  @moduledoc "Restricts admin screens to administrators."

  import Plug.Conn
  import Phoenix.Controller

  alias ConfluencePhxMirror.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = conn.assigns[:current_scope] || %Scope{}

    cond do
      Scope.admin?(scope) ->
        conn

      Scope.signed_in?(scope) ->
        conn
        |> put_flash(:error, "Administrator access required.")
        |> redirect(to: "/")
        |> halt()

      true ->
        conn
        |> put_flash(:error, "Please sign in.")
        |> redirect(to: "/session")
        |> halt()
    end
  end
end
