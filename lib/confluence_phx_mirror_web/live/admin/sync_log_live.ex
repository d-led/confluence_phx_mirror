defmodule ConfluencePhxMirrorWeb.Admin.SyncLogLive do
  @moduledoc """
  The sync as it happens: every page, file and failure, streaming.

  This is the counterpart of the audit log. The audit log answers "who changed
  what" long after the fact; this page answers "what is the sync doing right now
  and why is this page wrong?" — so it shows the chatty detail on purpose, and
  says nothing that has to survive a restart. Every call to Confluence is one of
  those lines, and the run ends with what all of them cost.

  Lines arrive over PubSub as the sync writes them, and the page seeds itself
  with whatever the log still holds, so opening it mid-run is useful. Following
  the tail is on by default and is a toggle: pressing it, or scrolling back to
  read, stops the page from pulling the reader down while the lines keep coming.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Confluence.Traffic
  alias ConfluencePhxMirror.Sync.Log

  @level_options [
    {"all", "Everything"},
    {"info", "Info and up"},
    {"warn", "Warnings and errors"},
    {"error", "Errors only"}
  ]

  @levels %{"info" => ~w(info warn error)a, "warn" => ~w(warn error)a, "error" => ~w(error)a}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, Log.topic())

    entries = Log.entries()

    {:ok,
     assign(socket,
       entries: entries,
       visible: filter_entries(entries, "all", ""),
       level: "all",
       query: "",
       follow?: true,
       level_options: @level_options,
       counts: count(entries),
       traffic: Traffic.summary(),
       page_title: "Sync log"
     )}
  end

  @impl true
  def handle_event("set_level", %{"level" => level}, socket) do
    entries = socket.assigns.entries
    level = if level in Map.keys(@levels) or level == "all", do: level, else: "all"

    {:noreply,
     assign(socket,
       level: level,
       visible: filter_entries(entries, level, socket.assigns.query)
     )}
  end

  def handle_event("filter", %{"q" => query}, socket) do
    query = String.trim(query || "")
    entries = socket.assigns.entries

    {:noreply,
     assign(socket,
       query: query,
       visible: filter_entries(entries, socket.assigns.level, query)
     )}
  end

  # The tail is followed by default. Pressing the button (or scrolling back, which
  # the page reports the same way) stops the page from dragging the reader away
  # from what they are reading; the lines keep arriving either way.
  def handle_event("toggle_follow", _params, socket) do
    {:noreply, assign(socket, :follow?, not socket.assigns.follow?)}
  end

  def handle_event("scrolled", %{"follow" => follow}, socket) when is_boolean(follow) do
    {:noreply, assign(socket, :follow?, follow)}
  end

  def handle_event("clear", _params, socket) do
    Log.clear()

    {:noreply, assign(socket, entries: [], visible: [], counts: count([]))}
  end

  @impl true
  def handle_info({:sync_log, entry}, socket) do
    entries = Enum.take(socket.assigns.entries ++ [entry], -Log.limit())

    socket =
      socket
      |> assign(entries: entries, counts: count(entries), traffic: Traffic.summary())
      |> assign(:visible, filter_entries(entries, socket.assigns.level, socket.assigns.query))
      |> push_event("sync-log:new", %{count: length(socket.assigns.visible)})

    {:noreply, socket}
  end

  defp filter_entries(entries, level, query) do
    levels = Map.get(@levels, level, ~w(debug info warn error)a)
    needle = String.downcase(query)

    Enum.filter(entries, fn entry ->
      entry.level in levels and
        (needle == "" or String.contains?(String.downcase(entry.message), needle) or
           String.contains?(String.downcase(inspect(entry.details)), needle))
    end)
  end

  defp count(entries) do
    Enum.reduce(entries, %{info: 0, debug: 0, warn: 0, error: 0}, fn entry, acc ->
      Map.update(acc, entry.level, 1, &(&1 + 1))
    end)
  end

  defp level_badge(:debug), do: {"·", "text-base-content/70"}
  defp level_badge(:info), do: {"info", "text-base-content/70"}
  defp level_badge(:warn), do: {"warn", "text-warning"}
  defp level_badge(:error), do: {"error", "text-error"}

  # A call's line already says the method, the path, the status and the
  # latency; only the facts that do not fit (the attempt, the wait) are added.
  defp details(%{kind: :http} = entry),
    do: details(entry.details, [:kind, :method, :url, :status, :ms, :bytes])

  defp details(entry), do: details(entry.details, [])

  defp details(details, hidden) do
    details
    |> Map.drop(hidden)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{detail_value(value)}" end)
  end

  defp detail_value(value) when is_binary(value), do: value
  defp detail_value(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp detail_value(value), do: inspect(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      mirror_host={@mirror_host}
      mirror_source={@mirror_source}
      page_title="Sync log"
      sidebar?={false}
    >
      <.admin_header
        current={:sync_log}
        title="Sync log"
        subtitle="Every page, file and Confluence call, line by line — kept in memory, not in the audit log."
      />

      <div class="mt-4 flex flex-wrap items-center gap-2">
        <form id="sync-log-filter" phx-change="filter" class="flex min-w-0 flex-1 items-center gap-2">
          <label class="input input-sm flex min-w-0 flex-1 items-center gap-2 rounded-lg border-base-300 bg-base-200/50">
            <.icon name="hero-funnel" class="size-4 opacity-50" />
            <input
              type="search"
              name="q"
              value={@query}
              placeholder="Filter lines by page, file, space or reason…"
              class="grow bg-transparent outline-none"
              phx-debounce="200"
              autocomplete="off"
            />
          </label>
        </form>

        <select
          id="sync-log-level"
          name="level"
          phx-change="set_level"
          class="select select-sm rounded-lg border-base-300"
          aria-label="Level"
        >
          <option :for={{value, label} <- @level_options} value={value} selected={value == @level}>
            {label}
          </option>
        </select>

        <button
          id="sync-log-follow"
          type="button"
          phx-click="toggle_follow"
          aria-pressed={to_string(@follow?)}
          title="Scroll to new lines as they arrive"
          class={[
            "btn btn-sm h-8 gap-1.5",
            @follow? && "btn-ghost",
            !@follow? && "btn-warning btn-soft"
          ]}
        >
          <.icon name={if @follow?, do: "hero-pause", else: "hero-play"} class="size-4" />
          {if @follow?, do: "Following", else: "Paused"}
        </button>

        <button id="sync-log-clear" type="button" phx-click="clear" class="btn btn-ghost btn-sm h-8">
          Clear
        </button>
      </div>

      <p class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/70">
        <span>{@counts.info} info</span>
        <span>{@counts.debug} debug</span>
        <span>{@counts.warn} warnings</span>
        <span>{@counts.error} errors</span>
        <span>·</span>
        <span>{length(@visible)} shown</span>
      </p>

      <p
        :if={@traffic.requests > 0}
        id="sync-log-traffic"
        class="mt-1 flex flex-wrap items-center gap-x-2 text-[11px] text-base-content/70"
      >
        <span class="font-semibold text-base-content/80">Confluence</span>
        <span>{Traffic.describe(@traffic)}</span>
      </p>

      <div
        id="sync-log"
        phx-hook=".Follow"
        data-follow={to_string(@follow?)}
        class="mt-2 max-h-[70vh] overflow-y-auto rounded-xl border border-base-300/70 bg-base-100 font-mono text-[11px]"
      >
        <p class="hidden only:block px-4 py-10 text-center font-sans text-sm text-base-content/70">
          Nothing yet. Lines appear here as soon as a sync starts, including every call it makes.
        </p>
        <div
          :for={entry <- @visible}
          id={"log-#{entry.id}"}
          class="flex flex-wrap items-baseline gap-x-2 border-b border-base-300/40 px-3 py-1.5 last:border-0"
        >
          <.local_time
            at={entry.at}
            class="w-28 shrink-0 tabular-nums text-base-content/70"
          />
          <span class={["w-10 shrink-0 lowercase", elem(level_badge(entry.level), 1)]}>
            {elem(level_badge(entry.level), 0)}
          </span>
          <span class="min-w-0 flex-1">
            {entry.message}
            <span :if={details(entry) != ""} class="text-base-content/70">· {details(entry)}</span>
          </span>
          <span :if={entry.run_id} class="shrink-0 text-base-content/70">#{entry.run_id}</span>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Follow">
        export default {
          mounted() {
            // Scrolling away from the newest line is how a reader says "let me
            // read": it turns following off without a second control.
            this.el.addEventListener("scroll", () => {
              const atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 40
              if (atBottom !== this.follow) this.pushEvent("scrolled", {follow: atBottom})
            })
            // The server pushes this after the diff, so the new line is already
            // in the DOM when the event arrives.
            this.handleEvent("sync-log:new", () => this.scrollToEnd())
            this.readToggle()
          },
          updated() {
            this.readToggle()
          },
          readToggle() {
            const follow = this.el.dataset.follow === "true"
            const turnedOn = follow && this.follow !== true
            this.follow = follow
            if (turnedOn) this.scrollToEnd()
          },
          scrollToEnd() {
            if (!this.follow) return
            // Reading scrollHeight forces the layout, so this includes the line
            // that just arrived.
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
