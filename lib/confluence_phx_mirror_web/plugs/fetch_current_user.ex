defmodule ConfluencePhxMirrorWeb.Plugs.FetchCurrentUser do
  @moduledoc "Loads the signed-in reader from the session."

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      case get_session(conn, :user_id) do
        nil -> nil
        id -> Accounts.get_user(id)
      end

    assign(conn, :current_user, user)
  end
end
