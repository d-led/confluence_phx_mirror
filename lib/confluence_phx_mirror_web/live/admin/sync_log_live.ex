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

  Each open page is its own watcher: it subscribes for itself and owns its own
  filter and follow toggle, so two admins watching the same sync see what each of
  them asked for. The lines themselves are a LiveView stream — the page keeps no
  copy of them, and a line arriving is one row inserted into the browser, not a
  re-render of the log. Changing the filter re-reads the ring once and replaces
  the rows; it never searches the log on the server. Clearing is the one action
  that reaches past one page: it empties the shared ring every page seeds itself
  from.
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

  @everything ~w(debug info warn error)a
  @levels %{"info" => ~w(info warn error)a, "warn" => ~w(warn error)a, "error" => ~w(error)a}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, Log.topic())

    %{entries: entries, counts: counts, held: held} = Log.snapshot()
    shown = filter_entries(entries, "all", "")

    {:ok,
     socket
     |> assign(
       level: "all",
       query: "",
       follow?: true,
       level_options: @level_options,
       counts: counts,
       held: held,
       shown: length(shown),
       newest_id: newest_id(entries),
       traffic: Traffic.summary(),
       page_title: "Sync log"
     )
     |> stream(:log, shown, limit: -Log.limit())}
  end

  @impl true
  # The level and the words are one filter, so they are one form and one event:
  # LiveView only reports a change for an input that lives in a form.
  def handle_event("filter", %{"q" => query, "level" => level}, socket) do
    socket =
      assign(socket,
        level: if(level in Map.keys(@levels) or level == "all", do: level, else: "all"),
        query: String.trim(query || "")
      )

    {:noreply, refilter(socket)}
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

  # The arrow over the log's corner says "back to the newest line", which is the
  # same thing as following again — the hook scrolls when that turns on.
  def handle_event("follow_newest", _params, socket) do
    {:noreply, assign(socket, :follow?, true)}
  end

  def handle_event("clear", _params, socket) do
    Log.clear()

    {:noreply, refilter(socket)}
  end

  @impl true
  def handle_info({:sync_log, entry, %{counts: counts, held: held}}, socket) do
    socket =
      if entry.id > socket.assigns.newest_id do
        socket
        |> add_line(entry)
        |> assign(counts: counts, held: held, newest_id: entry.id)
        |> announce_new_line()
      else
        # A line written between the page subscribing and seeding itself: the
        # seed already has it.
        socket
      end

    {:noreply, socket}
  end

  # One line is one insert: the lines already in the browser are not rendered
  # again, not re-counted, and not sent.
  defp add_line(socket, entry) do
    if passes?(entry, socket.assigns.level, socket.assigns.query) do
      socket
      |> stream_insert(:log, entry, at: -1, limit: -Log.limit())
      |> assign(:shown, min(socket.assigns.shown + 1, Log.limit()))
    else
      socket
    end
  end

  # Changing the filter is the one time the whole tail is re-read and the
  # browser is handed a fresh set of lines. A reader who is following lands on
  # the newest of them: the container was replaced, so the browser could not
  # keep its place anyway.
  defp refilter(socket) do
    %{entries: entries, counts: counts, held: held} = Log.snapshot()
    shown = filter_entries(entries, socket.assigns.level, socket.assigns.query)

    socket
    |> assign(counts: counts, held: held, shown: length(shown), newest_id: newest_id(entries))
    |> stream(:log, shown, reset: true, limit: -Log.limit())
    |> announce_new_line()
  end

  # Scrolling is the browser's business, and it only needs to hear about a line
  # it is following: a paused page is left where the reader put it.
  defp announce_new_line(socket) do
    if socket.assigns.follow?, do: push_event(socket, "sync-log:new", %{}), else: socket
  end

  defp newest_id([]), do: 0
  defp newest_id(entries), do: entries |> List.last() |> Map.fetch!(:id)

  # The ring's own limit as a module attribute: it is what makes a total a
  # ceiling, and a guard cannot call into another module.
  @limit Log.limit()

  defp shown_count(shown, held) when held >= @limit, do: "#{shown} of #{held} (max) shown"
  defp shown_count(shown, held), do: "#{shown} of #{held} shown"

  defp shown_tooltip(held) when held >= @limit,
    do: "The log keeps the last #{@limit} lines; older ones have fallen off the end."

  defp shown_tooltip(_held), do: "Every line the log holds."

  defp filter_entries(entries, level, query), do: Enum.filter(entries, &passes?(&1, level, query))

  defp passes?(entry, level, query) do
    needle = String.downcase(query)
    levels = Map.get(@levels, level, @everything)

    entry.level in levels and
      (needle == "" or String.contains?(String.downcase(entry.message), needle) or
         String.contains?(String.downcase(inspect(entry.details)), needle))
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

  attr :edge, :atom, required: true, values: [:top, :bottom]

  # The same four headings twice: one row sticks to the top of the scroller and
  # one to the bottom, so whichever end of the log a reader is at, the columns
  # are named.
  defp log_columns(assigns) do
    ~H"""
    <tr class="text-[10px] uppercase tracking-wider text-base-content/60">
      <th class={["w-[4.5rem] bg-base-200 px-3 py-1 text-left font-semibold", sticky(@edge)]}>
        Time
      </th>
      <th class={["w-14 bg-base-200 px-2 py-1 text-left font-semibold", sticky(@edge)]}>Level</th>
      <th class={["bg-base-200 px-2 py-1 text-left font-semibold", sticky(@edge)]}>Line</th>
      <th class={[
        "hidden w-16 bg-base-200 px-2 py-1 pr-3 text-right font-semibold sm:table-cell",
        sticky(@edge)
      ]}>
        Run
      </th>
    </tr>
    """
  end

  defp sticky(:top), do: "sticky top-0 z-10"
  defp sticky(:bottom), do: "sticky bottom-0 z-10"

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
      page_title="Sync log"
      sidebar?={false}
    >
      <.admin_header
        current={:sync_log}
        title="Sync log"
        subtitle="Every page, file and Confluence call, line by line — kept in memory, not in the audit log."
      />

      <div class="mt-4 flex flex-wrap items-center gap-2">
        <form
          id="sync-log-filter"
          phx-change="filter"
          phx-submit="filter"
          class="flex min-w-0 flex-1 items-center gap-2"
        >
          <label class="input input-sm flex min-w-0 flex-1 items-center gap-2 rounded-lg border-base-300 bg-base-200/50">
            <.icon name="hero-funnel" class="size-4 opacity-50" />
            <input
              type="search"
              name="q"
              value={@query}
              placeholder="Filter the lines as they arrive — page, file, space, reason…"
              title="Applies to this page's lines as they arrive, and to the lines it already holds. It does not search the log on the server."
              class="grow bg-transparent outline-none"
              phx-debounce="200"
              autocomplete="off"
            />
          </label>

          <select
            id="sync-log-level"
            name="level"
            class="select select-sm shrink-0 rounded-lg border-base-300"
            aria-label="Level"
          >
            <option :for={{value, label} <- @level_options} value={value} selected={value == @level}>
              {label}
            </option>
          </select>
        </form>

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
        <%!-- The log is a sliding window: once it is full, "400 of 400" means
        "at most 400", not "the 400 the sync wrote". --%>
        <span title={shown_tooltip(@held)}>{shown_count(@shown, @held)}</span>
      </p>

      <p
        :if={@traffic.requests > 0}
        id="sync-log-traffic"
        class="mt-1 flex flex-wrap items-center gap-x-2 text-[11px] text-base-content/70"
      >
        <span class="font-semibold text-base-content/80">Confluence</span>
        <%!-- A slowest call is a URL, and a URL has no spaces to wrap at: it
        must break, or it pushes the whole page sideways on a phone. --%>
        <span class="min-w-0 break-words">{Traffic.describe(@traffic)}</span>
      </p>

      <%!-- A table, not a pile of flex rows: the log scrolls, so the columns have
      to stay legible while it does. The header sticks to the top and repeats at
      the bottom, so a reader who scrolled past the newest line still knows what
      each column is. --%>
      <div class="relative">
        <div
          id="sync-log"
          phx-hook=".Follow"
          data-follow={to_string(@follow?)}
          class="mt-2 max-h-[70vh] overflow-y-auto rounded-xl border border-base-300/70 bg-base-100 text-[11px]"
        >
          <table class="w-full table-fixed border-collapse font-mono">
            <thead>
              <.log_columns edge={:top} />
            </thead>
            <tbody id="sync-log-rows" phx-update="stream">
              <tr
                :for={{dom_id, entry} <- @streams.log}
                id={dom_id}
                class="border-b border-base-300/40 align-baseline"
              >
                <td class="whitespace-nowrap px-3 py-1 align-baseline text-base-content/70">
                  <.local_time at={entry.at} format={:time} />
                </td>
                <td class={[
                  "whitespace-nowrap px-2 py-1 align-baseline",
                  elem(level_badge(entry.level), 1)
                ]}>
                  {elem(level_badge(entry.level), 0)}
                </td>
                <td class="min-w-0 px-2 py-1 align-baseline break-words">
                  {entry.message}
                  <span :if={details(entry) != ""} class="text-base-content/70">
                    · {details(entry)}
                  </span>
                </td>
                <%!-- The run is the first thing to go on a narrow screen: the line
              itself usually names it. --%>
                <td class="hidden whitespace-nowrap px-2 py-1 pr-3 text-right align-baseline text-base-content/70 sm:table-cell">
                  {entry.run_id && "##{entry.run_id}"}
                </td>
              </tr>
            </tbody>
            <tbody :if={@shown == 0}>
              <tr>
                <td colspan="4" class="px-4 py-10 text-center font-sans text-sm text-base-content/70">
                  Nothing yet. Lines appear here as soon as a sync starts, including every call it makes.
                </td>
              </tr>
            </tbody>
            <tfoot>
              <.log_columns edge={:bottom} />
            </tfoot>
          </table>
        </div>

        <%!-- New lines arrive at the bottom, and a reader who scrolled up to
        read one should not have to hunt for them: the arrow appears only while
        the log is paused, and taking it starts following again. --%>
        <button
          :if={!@follow?}
          id="sync-log-to-end"
          type="button"
          phx-click="follow_newest"
          title="Scroll to the newest line and follow again"
          aria-label="Scroll to the newest line"
          class="absolute bottom-3 right-4 z-10 grid size-9 place-items-center rounded-full border border-base-300 bg-base-100 text-base-content/70 shadow-md transition hover:bg-base-200 hover:text-primary"
        >
          <.icon name="hero-arrow-down" class="size-4" />
        </button>
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
