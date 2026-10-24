defmodule ConfluencePhxMirrorWeb.PagePresenceLive do
  @moduledoc """
  Who is reading this page, for its rail.

  A page is a controller response and has no process of its own, so
  `live_render/3` gives Presence one to track: the reader is on the page while
  this LiveView is alive, and gone when the tab closes.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.LiveUserAuth
  alias ConfluencePhxMirrorWeb.Presence

  @impl true
  def mount(_params, session, socket) do
    reader = LiveUserAuth.reader(session)

    case readable_page(session["presence_page"], Scope.for_user(reader)) do
      {:ok, page} ->
        {:ok, watching(socket, Presence.topic(page.confluence_id), reader)}

      :error ->
        # A page the reader cannot open is not found anywhere else either, so
        # nobody is listed: Presence names who is reading.
        {:ok, assign(socket, :readers, [])}
    end
  end

  defp watching(socket, topic, reader) do
    if connected?(socket) do
      Presence.subscribe(topic)

      {:ok, _} =
        Presence.track(self(), topic, Presence.key(reader), %{user: Presence.name(reader)})
    end

    assign(socket, :readers, Presence.readers(topic))
  end

  defp readable_page(confluence_id, scope) do
    with {id, ""} <- Integer.parse(to_string(confluence_id)),
         {:ok, page} <- Mirror.find_page(id),
         true <- Authorization.can_read_page?(scope, page) do
      {:ok, page}
    else
      _ -> :error
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    {:noreply, assign(socket, :readers, Presence.readers(topic))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="flex items-baseline gap-1.5">
        <span id="page-presence-count" class="text-2xl font-semibold tabular-nums">
          {length(@readers)}
        </span>
        <span class="text-xs text-base-content/70">reading this page</span>
      </p>
      <ul id="page-presence-readers" class="mt-2 space-y-1 text-xs text-base-content/70">
        <li :for={name <- @readers} class="truncate">{name}</li>
      </ul>
    </div>
    """
  end
end
