defmodule ConfluencePhxMirrorWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the signed-in reader from the session.

  An account switched off here, or one the site has deactivated, is nobody: the
  session is ignored rather than trusted, so a disabled reader loses access the
  moment the flag is set, without waiting for their cookie to expire.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Scope, User}

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      case get_session(conn, :user_id) do
        nil -> nil
        id -> id |> Accounts.get_user() |> active()
      end

    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, Scope.for_user(user))
  end

  defp active(%User{} = user), do: if(User.disabled?(user), do: nil, else: user)
  defp active(nil), do: nil
end
