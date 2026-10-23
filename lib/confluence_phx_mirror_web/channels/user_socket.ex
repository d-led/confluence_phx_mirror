defmodule ConfluencePhxMirrorWeb.UserSocket do
  @moduledoc "Socket for reader presence (separate from the LiveView socket)."

  use Phoenix.Socket

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope

  channel "page:*", ConfluencePhxMirrorWeb.PageChannel
  channel "site", ConfluencePhxMirrorWeb.SiteChannel

  @impl true
  def connect(_params, %Phoenix.Socket{} = socket, %{session: session}) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> Accounts.get_user(id)
      end

    {:ok,
     assign(socket,
       user_id: user && user.id,
       user_email: user && user.email,
       user_name: user && user.display_name,
       scope: Scope.for_user(user)
     )}
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    case socket.assigns[:user_id] do
      nil -> nil
      user_id -> "user:#{user_id}"
    end
  end
end
