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
       reader_key: reader_key(user),
       user_id: user && user.id,
       user_email: user && user.email,
       user_name: user && user.display_name,
       scope: Scope.for_user(user)
     )}
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Who a reader is, for Presence: their account — two tabs are one person —
  # or, when anonymous, this very connection, since nothing else tells
  # anonymous readers apart. `id/1` stays nil for them: there is no second
  # connection to identify them by.
  defp reader_key(nil),
    do: "reader:" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp reader_key(user), do: "user:#{user.id}"

  @impl true
  def id(socket) do
    case socket.assigns[:user_id] do
      nil -> nil
      user_id -> "user:#{user_id}"
    end
  end
end
