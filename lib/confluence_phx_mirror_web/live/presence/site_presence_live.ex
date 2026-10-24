defmodule ConfluencePhxMirrorWeb.SitePresenceLive do
  @moduledoc """
  How many people have the mirror open, for the footer.

  Every page renders this with `live_render/3`, so Presence has a process to
  track on the controller-rendered pages as well as the LiveView ones.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirrorWeb.LiveUserAuth
  alias ConfluencePhxMirrorWeb.Presence

  @impl true
  def mount(_params, session, socket) do
    topic = Presence.site_topic()

    if connected?(socket) do
      Presence.subscribe(topic)

      key = session |> LiveUserAuth.reader() |> Presence.key() |> Presence.site_key()
      {:ok, _} = Presence.track(self(), topic, key, %{})
    end

    {:ok, assign(socket, :online, Presence.online_count())}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online, Presence.online_count())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1" title="People with the mirror open right now">
      <.icon name="hero-users" class="size-3" />
      <span>
        Users online: <span id="site-presence-count" class="tabular-nums">{@online}</span>
      </span>
    </span>
    """
  end
end
