defmodule ConfluencePhxMirrorWeb.Plugs.RequireAdmin do
  @moduledoc """
  Admin-only pages that are not LiveViews.

  Live admin screens are guarded by `LiveUserAuth`'s `:admin` hook; a static
  admin page has to answer the same way, so an anonymous reader is sent to sign
  in and a signed-in member is sent home with a flash — never a 403 that tells
  them what they are missing.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias ConfluencePhxMirror.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = Scope.from_assigns(conn.assigns)

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
