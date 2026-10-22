defmodule ConfluencePhxMirrorWeb.PageChannel do
  @moduledoc """
  Joins readers to `page:<confluence_id>` and tracks them with Presence.

  Anonymous readers are tracked per socket; signed-in readers are tracked per
  user id, so opening the same page in two tabs does not inflate the count.
  """

  use Phoenix.Channel

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.Presence

  @impl true
  def join("page:" <> confluence_id, _payload, socket) do
    with {id, ""} <- Integer.parse(confluence_id),
         {:ok, page} <- Mirror.find_page(id),
         true <- readable?(socket, page) do
      send(self(), :after_join)
      {:ok, assign(socket, :page, page)}
    else
      _ -> {:error, %{reason: "page_not_found"}}
    end
  end

  # Presence shows who is reading a page, so it may only be asked about a page
  # the reader could open: a restricted page is not found, like everywhere else.
  defp readable?(socket, page) do
    scope = socket.assigns[:scope] || Scope.for_user(nil)
    Authorization.can_read_page?(scope, page)
  end

  @impl true
  def handle_info(:after_join, socket) do
    topic = Presence.topic(socket.assigns.page.confluence_id)

    {:ok, _} =
      Presence.track(socket, key(socket), %{
        online_at: System.system_time(:second),
        user: display_name(socket),
        page_id: socket.assigns.page.confluence_id
      })

    push(socket, "presence_state", Presence.list(topic))
    {:noreply, socket}
  end

  defp key(socket) do
    case socket.assigns[:user_id] do
      nil -> socket.id
      user_id -> "user:#{user_id}"
    end
  end

  defp display_name(socket) do
    case socket.assigns[:user_name] || socket.assigns[:user_email] do
      nil -> "Anonymous reader"
      name -> name
    end
  end
end
