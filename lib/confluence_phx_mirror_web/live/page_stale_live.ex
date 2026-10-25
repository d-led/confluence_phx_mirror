defmodule ConfluencePhxMirrorWeb.PageStaleLive do
  @moduledoc """
  "This page was re-synced while you were reading it" — offered, not imposed.

  The reader's page is a controller response, so this island is the only process
  it has. It subscribes to `ConfluencePhxMirror.PageUpdates` for the one page it
  was rendered with, and stays out of the way until a sync writes that page.
  Then it shows a small notice in the corner of the screen with a reload, and
  keeps it until the reader takes one of the two buttons.

  It never reloads anything itself: the reader is reading, and a screen that
  jumps under their eyes is worse than a page that is a minute old. The copy it
  already shows is named, too — a write the reader has already been given (the
  page arrived after the sync) is not news.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.PageUpdates

  @impl true
  def mount(_params, session, socket) do
    page_id = page_id(session)

    if connected?(socket) and page_id, do: PageUpdates.subscribe(page_id)

    {:ok,
     assign(socket,
       page_id: page_id,
       path: session["stale_path"],
       seen_at: session["stale_synced_at"],
       updated?: false
     )}
  end

  @impl true
  def handle_info({:page_synced, _page_id, at}, socket) do
    if newer?(at, socket.assigns.seen_at) do
      {:noreply, assign(socket, updated?: true, seen_at: at)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, :updated?, false)}
  end

  # Nothing is rendered until there is something to say: the island is quiet on
  # a page nobody has touched, and appears in a corner of the screen when one
  # has been written again.
  @impl true
  def render(assigns) do
    ~H"""
    <div
      :if={@updated?}
      id="page-stale-notice"
      role="status"
      aria-live="polite"
      class={[
        "fixed bottom-4 left-1/2 z-40 flex -translate-x-1/2 items-center gap-3 rounded-full",
        "border border-base-300 bg-base-100 py-1.5 pl-4 pr-1.5 text-xs shadow-lg"
      ]}
    >
      <span class="text-base-content/80">This page was re-synced while you were reading it.</span>
      <a
        id="page-stale-reload"
        href={@path}
        class="btn btn-primary btn-xs gap-1.5"
        title="Load the page the sync just stored"
      >
        <.icon name="hero-arrow-path" class="size-3.5" /> Reload
      </a>
      <button
        id="page-stale-dismiss"
        type="button"
        phx-click="dismiss"
        class="btn btn-ghost btn-xs"
        title="Keep reading this copy"
        aria-label="Dismiss"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  defp page_id(session) do
    case Integer.parse(to_string(session["stale_page_id"])) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp newer?(nil, _seen), do: false
  defp newer?(_at, nil), do: true
  defp newer?(at, seen), do: at > seen
end
