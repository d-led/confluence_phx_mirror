defmodule ConfluencePhxMirrorWeb.Plugs.FetchCurrentUser do
  @moduledoc "Loads the signed-in reader from the session."

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      case get_session(conn, :user_id) do
        nil -> nil
        id -> Accounts.get_user(id)
      end

    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, Scope.for_user(user))
  end
end
