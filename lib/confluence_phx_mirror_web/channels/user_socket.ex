defmodule ConfluencePhxMirrorWeb.UserSocket do
  @moduledoc "Socket for reader presence (separate from the LiveView socket)."

  use Phoenix.Socket

  alias ConfluencePhxMirror.Accounts

  channel "page:*", ConfluencePhxMirrorWeb.PageChannel

  @impl true
  def connect(_params, %{session: session}, socket) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> Accounts.get_user(id)
      end

    {:ok, assign(socket, user_id: user && user.id, user_email: user && user.email)}
  end

  def connect(_params, _info, _socket), do: :error

  @impl true
  def id(socket) do
    case socket.assigns[:user_id] do
      nil -> nil
      user_id -> "user:#{user_id}"
    end
  end
end
