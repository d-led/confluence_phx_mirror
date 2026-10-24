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

  import ConfluencePhxMirrorWeb.AdminComponents

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
       events: Audit.search(limit: @page_size),
       page_title: "Audit log"
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
      live={@socket}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      mirror_host={@mirror_host}
      mirror_source={@mirror_source}
      page_title="Audit log"
      sidebar?={false}
    >
      <.admin_header
        current={:audit}
        title="Audit log"
        subtitle="Every change the mirror made or saw — newest first, append-only."
      />

      <%!-- One box for what the reader knows — "jane role", "sync failed" — and
      two menus to narrow what the words cannot say. The box takes the room;
      a menu is as wide as the action it names. --%>
      <form id="audit-filter" phx-change="filter" class="mt-5 flex flex-wrap items-center gap-2">
        <label class="input input-sm flex min-w-0 flex-1 basis-56 items-center gap-2 rounded-lg border-base-300 bg-base-200/50">
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0 opacity-50" />
          <input
            type="search"
            name="q"
            value={@query}
            placeholder="Filter"
            aria-label="Filter the log"
            title="Every word has to match the action, the actor, the id or the details"
            class="grow bg-transparent outline-none"
            phx-debounce="250"
            autocomplete="off"
          />
        </label>

        <select
          name="action"
          class="select select-sm w-auto max-w-44 shrink-0 rounded-lg"
          aria-label="Action"
        >
          <option value="">Any action</option>
          <option :for={action <- @actions} value={action} selected={action == @action}>
            {action}
          </option>
        </select>

        <select
          name="actor"
          class="select select-sm w-auto max-w-32 shrink-0 rounded-lg"
          aria-label="Actor"
        >
          <option value="">Any actor</option>
          <option :for={type <- @actor_types} value={type} selected={type == @actor_type}>
            {type}
          </option>
        </select>

        <.link
          :if={filtered?(@query, @action, @actor_type)}
          patch={~p"/admin/audit"}
          id="audit-clear"
          class="btn btn-ghost btn-sm gap-1 rounded-lg text-base-content/70"
        >
          <.icon name="hero-x-mark" class="size-4" /> Clear
        </.link>
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
          <.local_time
            at={event.inserted_at}
            class="w-24 shrink-0 text-[11px] text-base-content/70"
          >
            {Time.ago(event.inserted_at)}
          </.local_time>

          <div class="min-w-0 flex-1">
            <p class="text-sm">{Audit.describe(event)}</p>
            <%!-- The action is the machine's name for what happened, so it
            belongs with the identifiers on the second line: in the middle of
            the sentence it wrapped onto a line of its own and moved from row
            to row. --%>
            <p class="mt-0.5 text-[11px] text-base-content/70">
              <span class="font-mono text-[10px] uppercase tracking-wide">{event.action}</span>
              · {Audit.actor(event)} · {event.entity_type} #{event.entity_id}
              <%= for {key, value} <- facts(event) do %>
                · <span class="text-base-content/70">{key}</span> {value}
              <% end %>
            </p>
          </div>
        </li>

        <li :if={@events == []} class="px-4 py-10 text-center text-sm text-base-content/70">
          No events match this filter.
          <%!-- A sentence is written from the event, so a reader may well have
          typed words the search does not carry ("no changes" is drawn from a
          counter). Saying what is searched is the difference between an empty
          log and a broken one. --%>
          <span
            :if={filtered?(@query, @action, @actor_type)}
            class="mt-1 block text-xs text-base-content/60"
          >
            Every word has to match the action, the actor, the id or the details.
          </span>
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
  # `trigger` is left out on purpose — the sentence already ends with it, and a
  # row that says "triggered by the hourly schedule" twice is the sort of noise
  # that makes an audit log unreadable. `source` is *not* left out: the sentence
  # never names the site, and "which Confluence" is the first question asked of
  # a sync that copied the wrong thing.
  @described ~w(email title role from to groups mode error filename count name prefix version page space event
               event_type stats status trigger)

  @pairs_on_a_line 3

  # A log nobody filtered is the whole log; saying so is what "Clear" is for.
  defp filtered?(query, action, actor), do: query != "" or action != "" or actor != ""

  defp facts(%{metadata: metadata}) do
    metadata
    |> Map.drop(@described)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(4)
    |> Enum.map(fn {key, value} -> {key, fact(value)} end)
  end
  # A fact can be a map — a queued job's arguments, a settings diff — and the
  # row keeps it whole for the JSON API. A line of the log says the first few
  # pairs and counts the rest: what changed belongs here, every byte of it does
  # not.
  defp fact(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, inner} -> "#{key}=#{fact(inner)}" end)
    case pairs do
      [] ->
        "—"
      pairs when length(pairs) <= @pairs_on_a_line ->
        Enum.join(pairs, ", ")
      pairs ->
        Enum.join(Enum.take(pairs, @pairs_on_a_line), ", ") <>
          " +#{length(pairs) - @pairs_on_a_line}"
    end
  end
  defp fact(value) when is_list(value) do
    case Enum.map(value, &fact/1) do
      [] -> "—"
      parts -> Enum.join(parts, ", ")
    end
  end
  defp fact(nil), do: "—"
  defp fact(value) when is_binary(value), do: value
  defp fact(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp fact(value), do: inspect(value)
end
