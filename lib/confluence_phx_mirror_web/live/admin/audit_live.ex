defmodule ConfluencePhxMirrorWeb.Admin.AuditLive do
  @moduledoc """
  The audit log: every change the mirror made or saw, newest first.

  The page is a filterable table rather than a feed, because the questions asked
  of an audit log are "who did that", "what happened to this account" and "what
  did the last sync do" — all of them filters, not scrollbacks. New events
  arrive live: the log broadcasts each one on `Audit.topic/0` while the page is
  open.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirrorWeb.Time

  @page_size 50
  @actor_types ~w(user system webhook)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, Audit.topic())

    {:ok,
     assign(socket,
       query: "",
       action: "",
       actor_type: "",
       actions: Audit.actions(),
       actor_types: @actor_types,
       page_size: @page_size,
       offset: 0,
       events: Audit.search(limit: @page_size)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      query: params["q"] || "",
      action: params["action"] || "",
      actor_type: params["actor"] || ""
    }

    {:noreply, socket |> assign(filters) |> assign(:offset, 0) |> reload()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = String.trim(params["q"] || "")

    {:noreply,
     push_patch(socket,
       to: ~p"/admin/audit?#{%{q: query, action: params["action"], actor: params["actor"]}}"
     )}
  end

  def handle_event("load_more", _params, socket) do
    offset = socket.assigns.offset + @page_size

    {:noreply,
     socket
     |> assign(:offset, offset)
     |> assign(:events, socket.assigns.events ++ search(socket, offset))}
  end

  @impl true
  def handle_info({:audit_event, event}, socket) do
    # Only the unfiltered, first page grows live; anything else would contradict
    # the filter the reader is looking at.
    if socket.assigns.offset == 0 and socket.assigns.query == "" and
         socket.assigns.action == "" and socket.assigns.actor_type == "" do
      {:noreply, assign(socket, :events, Enum.take([event | socket.assigns.events], @page_size))}
    else
      {:noreply, socket}
    end
  end

  defp reload(socket) do
    assign(socket, :events, search(socket, 0))
  end

  defp search(socket, offset) do
    %{query: query, action: action, actor_type: actor} = socket.assigns

    Audit.search(
      query: query,
      action: action,
      actor_type: actor,
      limit: @page_size,
      offset: offset
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_source={@mirror_source}
      page_title="Audit log"
      sidebar?={false}
    >
      <header class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300/70 pb-4">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">
            Administration
          </p>
          <h1 class="mt-1 text-2xl font-semibold">Audit log</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Every change the mirror made or saw — newest first, append-only.
          </p>
        </div>
        <.link navigate={~p"/admin"} class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-left" class="size-4" /> Dashboard
        </.link>
      </header>

      <form id="audit-filter" phx-change="filter" class="mt-5 flex flex-wrap items-center gap-2">
        <label class="input input-sm flex min-w-0 flex-1 items-center gap-2 rounded-lg border-base-300 bg-base-200/50">
          <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
          <input
            type="search"
            name="q"
            value={@query}
            placeholder="Filter by action, actor or the id/email it happened to…"
            class="grow bg-transparent outline-none"
            phx-debounce="250"
            autocomplete="off"
          />
        </label>

        <select name="action" class="select select-sm rounded-lg" aria-label="Action">
          <option value="">Any action</option>
          <option :for={action <- @actions} value={action} selected={action == @action}>
            {action}
          </option>
        </select>

        <select name="actor" class="select select-sm rounded-lg" aria-label="Actor">
          <option value="">Any actor</option>
          <option :for={type <- @actor_types} value={type} selected={type == @actor_type}>
            {type}
          </option>
        </select>
      </form>

      <ul
        id="audit-log"
        class="mt-4 divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300/70 bg-base-100"
      >
        <li
          :for={event <- @events}
          id={"audit-#{event.id}"}
          class="flex flex-wrap gap-x-4 gap-y-1 px-4 py-3"
        >
          <time
            class="w-24 shrink-0 text-[11px] text-base-content/45"
            title={Time.datetime(event.inserted_at)}
          >
            {Time.ago(event.inserted_at)}
          </time>

          <div class="min-w-0 flex-1">
            <p class="text-sm">
              <span class="font-medium">{Audit.describe(event)}</span>
              <span class="ml-1 font-mono text-[10px] uppercase tracking-wide text-base-content/35">
                {event.action}
              </span>
            </p>
            <p class="mt-0.5 text-[11px] text-base-content/50">
              {Audit.actor(event)} · {event.entity_type} #{event.entity_id}
              <%= for {key, value} <- details(event) do %>
                · <span class="text-base-content/40">{key}</span> {value}
              <% end %>
            </p>
          </div>
        </li>

        <li :if={@events == []} class="px-4 py-10 text-center text-sm text-base-content/50">
          No events match this filter.
        </li>
      </ul>

      <div :if={length(@events) >= @page_size and @events != []} class="mt-4 flex justify-center">
        <button type="button" phx-click="load_more" class="btn btn-ghost btn-sm">
          Load older events
        </button>
      </div>
    </Layouts.app>
    """
  end

  # The facts that did not fit in the sentence: identifiers, versions, counts.
  @described ~w(email title role from to groups mode source error filename count name prefix version page space event event_type stats status)

  defp details(%{metadata: metadata}) do
    metadata
    |> Map.drop(@described)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(4)
  end
end
