defmodule ConfluencePhxMirrorWeb.SiteChannel do
  @moduledoc """
  Joins every reader to the site topic, which the footer counts.

  Only the number of readers is published, so a reader is tracked without a
  name: who is reading a page is only told to the readers of that page.
  """

  use Phoenix.Channel

  alias ConfluencePhxMirrorWeb.Presence

  @impl true
  def join("site", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(socket, Presence.reader_key(socket), %{})
    push(socket, "presence_state", Presence.list(socket.topic))
    {:noreply, socket}
  end
end
