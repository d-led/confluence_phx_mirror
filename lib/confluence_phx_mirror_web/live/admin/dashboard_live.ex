defmodule ConfluencePhxMirrorWeb.Admin.DashboardLive do
  @moduledoc """
  The overview: freshness, sync runs, recent activity and the actions an
  operator needs during a demo or an incident.

  Everything here is a pointer or a summary. The sync log streams the detail,
  `/admin/audit` holds every event, and `/admin/webhooks` holds the deliveries;
  those pages exist so this one stays a glance rather than a dump.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import Ecto.Query
  import ConfluencePhxMirrorWeb.UIComponents
  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Confluence.Traffic
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Resources
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{ReconcileRun, SnapshotWorker, SpaceWorker, SweepWorker}
  alias ConfluencePhxMirror.Sync.SyncRun
  alias ConfluencePhxMirrorWeb.Plugs
  alias ConfluencePhxMirrorWeb.Time

  # Two cadences, because two kinds of number live here. What a run is doing
  # moves by the second and is the thing an operator sits and watches, so the
  # strip above the totals is re-read every five seconds. The totals, the run
  # table, the audit tail and the resource figures move slowly — a mirror's page
  # count does not change between heartbeats — so they are re-read on their own,
  # longer interval, which a deployment can set
  # (`CM_ADMIN_STATS_REFRESH_SECONDS`, 30 by default).
  @progress_ms 5_000
  @stats_seconds 30

  # The "sync one space" panel narrows in the database and takes a window: a
  # site with hundreds of spaces should not feel like a list of hundreds.
  @space_window 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@progress_ms, self(), :progress)
      :timer.send_interval(stats_refresh_ms(), self(), :stats)
    end

    {:ok,
     socket
     |> assign(page_title: "Overview", open_menu: nil, space_query: "", queued: nil)
     |> assign(spaces_like(""))
     |> load()}
  end

  @impl true
  def handle_info(:stats, socket), do: {:noreply, assign_stats(socket)}

  def handle_info(:progress, socket) do
    refreshed = assign_progress(socket)

    # A run that just ended is the one moment the slow numbers are wrong in a
    # way an operator notices: the strip is gone and the row still says
    # "running". Catching the table up here costs one read, once per run.
    if socket.assigns.running && is_nil(refreshed.assigns.running) do
      {:noreply, assign_stats(refreshed)}
    else
      {:noreply, refreshed}
    end
  end

  # An administrator decides how long the overview waits for the totals to move;
  # a zero or negative value would mean a request loop, so a nonsense value
  # falls back to the built-in cadence.
  defp stats_refresh_ms do
    case Settings.dashboard_refresh_seconds() do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1000
      _nonsense -> @stats_seconds * 1000
    end
  end

  # Every event is a name and a handler: the clauses are one line each, so this
  # function reads as the table of what the dashboard can be asked to do.
  @impl true
  def handle_event("toggle_menu", params, socket), do: toggle_menu(params, socket)
  def handle_event("close_menu", params, socket), do: close_menu(params, socket)
  def handle_event("space_query", params, socket), do: space_query(params, socket)
  def handle_event("snapshot", params, socket), do: snapshot(params, socket)
  def handle_event("full_sync", params, socket), do: full_sync(params, socket)
  def handle_event("sync_space", params, socket), do: sync_space(params, socket)
  def handle_event("cancel_sync", params, socket), do: cancel_sync(params, socket)
  def handle_event("cancel_queued", params, socket), do: cancel_queued(params, socket)

  # One dropdown, so a single name: opening it twice closes it, Escape closes
  # it, and a click anywhere else does too.
  defp toggle_menu(%{"menu" => menu}, socket) do
    open = if socket.assigns.open_menu == menu, do: nil, else: menu
    {:noreply, assign(socket, :open_menu, open)}
  end

  defp close_menu(_params, socket) do
    {:noreply, socket |> assign(open_menu: nil, space_query: "") |> assign(spaces_like(""))}
  end

  defp space_query(%{"space" => query}, socket) do
    {:noreply, socket |> assign(:space_query, query) |> assign(spaces_like(query))}
  end

  defp snapshot(_params, socket) do
    queued =
      %{"trigger" => requested_by(socket), "scope" => "the whole site, what changed"}
      |> SnapshotWorker.new()
      |> Oban.insert()

    {:noreply, notice(socket, queued, "A sync of what changed")}
  end

  defp full_sync(_params, socket) do
    queued =
      %{"trigger" => "#{requested_by(socket)}, re-reading everything", "scope" => "every space"}
      |> SweepWorker.new()
      |> Oban.insert()

    {:noreply, notice(socket, queued, "A full re-read, one space at a time")}
  end

  defp sync_space(%{"key" => key}, socket) do
    queued =
      %{"space_key" => key, "trigger" => requested_by(socket)}
      |> SpaceWorker.new()
      |> Oban.insert()

    socket
    |> assign(open_menu: nil, space_query: "")
    |> assign(spaces_like(""))
    |> notice(queued, "A refresh of #{key}")
    |> then(&{:noreply, &1})
  end

  # A queued job is only useful if the operator can find it again: the notice
  # names it and links to its row on Jobs, where the worker's own record is.
  defp notice(socket, {:ok, job}, what) do
    socket
    |> assign(:queued, %{job: job, what: what})
    |> put_flash(:info, "#{what} is queued.")
  end

  defp notice(socket, {:error, reason}, what) do
    put_flash(socket, :error, "Could not queue #{String.downcase(what)}: #{inspect(reason)}")
  end

  # A cancel either exits the process doing the work (this node) or records the
  # request for a run elsewhere; either way the table shows the status on the
  # next tick.
  defp cancel_sync(%{"run_id" => run_id}, socket) do
    case Sync.cancel(run_id, {:user, socket.assigns.current_user}) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cancelling: the run is being stopped now.")
         |> load()}

      {:error, :not_running} ->
        {:noreply, socket |> put_flash(:error, "That run is not running any more.") |> load()}
    end
  end

  # A queued job has not started, so dropping it is a queue operation: it never
  # becomes a run, and nothing has to be interrupted.
  defp cancel_queued(%{"id" => id}, socket) do
    case Sync.cancel_queued(String.to_integer(id), {:user, socket.assigns.current_user}) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Dropped from the queue: that sync will not run.")
         |> load()}

      {:error, :not_queued} ->
        {:noreply,
         socket
         |> put_flash(:error, "That one already started, so it is a run now. Its line is above.")
         |> load()}
    end
  end

  # The menu's list is a database answer: name or key contains the words typed,
  # a window of twenty, alphabetical. Nothing is filtered in the browser. When
  # the window is not the whole answer the panel says so, and points at the
  # screen that pages through all of them.
  defp spaces_like(query) do
    [
      sync_spaces: Mirror.list_spaces(query: query, limit: @space_window),
      sync_spaces_more?: Mirror.count_listed_spaces(query: query) > @space_window
    ]
  end

  # What the find box in "sync one space" offers: the name a reader looks for
  # and the key they recognise, nothing else.
  defp space_options(spaces) do
    Enum.map(spaces, &%{value: &1.key, label: &1.name, badge: &1.key})
  end

  # What the running run is doing, in numbers that move: the counters are
  # written by the sync as it counts, `Traffic` keeps what the calls cost, and
  # this page re-reads both every few seconds.
  defp progress(nil), do: nil

  defp progress(run) do
    traffic = Traffic.summary()
    stats = run.stats || %{}
    elapsed_s = max(DateTime.diff(DateTime.utc_now(), run.started_at, :second), 1)
    pages = Map.get(stats, "pages", 0)

    %{
      phase: phase_label(Map.get(stats, "phase")),
      mode: run.mode,
      trigger: Map.get(stats, "trigger") || "the schedule",
      running_for: Time.duration(run.started_at, DateTime.utc_now()),
      pages: pages,
      requests: traffic.requests,
      bytes: traffic.bytes,
      retries: traffic.retries,
      failed: traffic.failed,
      pace: "#{Float.round(pages / elapsed_s, 1)} pages/s"
    }
  end

  # The steps a run walks, in the order `Sync` walks them: a table, because the
  # sentence for a phase is data, not a decision.
  @phases %{
    "people" => "reading people and groups",
    "spaces" => "reading spaces",
    "pages" => "reading pages",
    "details" => "reading comments, files and restrictions",
    "accounts" => "checking the site's accounts"
  }

  # The site's number beside ours, in the few words that fit a strip.
  defp pages_hint(held, %{named: named}) when held > named,
    do: "#{grouped(held - named)} not in Confluence"

  defp pages_hint(_held, %{named: named}), do: "Confluence has #{grouped(named)}"

  defp grouped(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp phase_label(nil), do: "talking to the site"
  defp phase_label(phase), do: Map.get(@phases, phase, phase)

  # "58 GB free of 926 GB on /data": the sentence an operator reads when a sync
  # is about to run out of room.
  defp device_line(%{device: nil}), do: "the device did not report its size"

  defp device_line(%{device: device}) do
    "#{human_bytes(device.free_bytes)} free of #{human_bytes(device.total_bytes)} on #{device.mount}"
  end

  defp table_line([]), do: "the database did not report its tables"

  defp table_line(tables) do
    "biggest: " <>
      Enum.map_join(tables, ", ", fn {name, bytes} -> "#{name} #{human_bytes(bytes)}" end)
  end

  # Postgres says what it uses and never what is left, so a bar is only honest
  # when the deployment told us how big the volume is.
  defp database_percent(_database, capacity) when not is_integer(capacity), do: nil

  defp database_percent(%{tablespace_bytes: used}, capacity) do
    round(used * 100 / capacity)
  end

  defp database_line(%{bytes: bytes, tablespace_bytes: on_disk}, nil) do
    "#{human_bytes(bytes)} database, " <>
      "#{human_bytes(on_disk)} in the default tablespace (WAL and any other database in it)"
  end

  defp database_line(%{bytes: bytes}, capacity) do
    "#{human_bytes(bytes)} database of a #{human_bytes(capacity)} volume"
  end

  # The third colour on a bar: how much of the device this deployment accounts
  # for. A device that did not report its size gets no colour — a share of an
  # unknown whole is a guess, and a bar that guesses is worse than no bar.
  defp share_percent(_bytes, total) when not is_integer(total), do: nil
  defp share_percent(_bytes, total) when total <= 0, do: nil

  defp share_percent(bytes, total),
    do: (bytes * 100 / total) |> Float.round(1) |> min(100)

  # "2.8 GB free of 16 GB" — memory is read the way a disk is, and the mirror's
  # own heap sits underneath it, because that is the part a sync grows.
  defp memory_line(%{available_bytes: available, total_bytes: total}) do
    "#{human_bytes(available)} available of #{human_bytes(total)}"
  end

  # The audit log answers "who asked for this?" for every run, so a manual one
  # carries the address of the admin who pressed the button.
  defp requested_by(socket) do
    case socket.assigns[:current_user] do
      nil -> "the admin dashboard"
      user -> "the admin dashboard, by #{user.email}"
    end
  end

  defp load(socket), do: socket |> assign_stats() |> assign_progress()

  # Everything that changes slowly enough to be read on the configured interval:
  # the totals, the run table, the audit tail, the recent pages, and what this
  # node occupies.
  defp assign_stats(socket) do
    runs =
      Repo.all(
        from r in SyncRun,
          order_by: [desc: r.started_at],
          limit: 8
      )

    assign(socket,
      paused?: ConfluencePhxMirror.Settings.sync_paused?(),
      stats: Mirror.stats(),
      # What this node occupies and the room beside it: the mount is the last
      # measurement (a walk of every attachment file, once a minute), the
      # database a catalogue lookup on this tick.
      resources: Resources.mount(),
      database: Resources.database(),
      database_capacity: Resources.database_capacity(),
      memory: Resources.memory(),
      # The shell's switcher draws a window of the directory, so the dashboard
      # sends a window.
      spaces: Mirror.list_spaces(limit: Plugs.SiteContext.switcher_limit()),
      # Queue and history are one list: what waits is what an operator can still
      # stop, and it reads next to what already ran.
      rows: sync_rows(Sync.queued(), runs),
      audit: Audit.recent(18),
      recent_pages: Mirror.recent_pages(8),
      last_sync: Mirror.last_successful_sync_run(),
      # What the site counts, from the last check that asked it. The number here
      # is what the mirror holds; without this one, "are these the same?" is a
      # question only a full re-read could answer.
      upstream: upstream_pages()
    )
  end

  defp upstream_pages do
    case ReconcileRun.last_finished() do
      nil ->
        nil

      run ->
        summary = ReconcileRun.summary(run)
        %{named: summary.named, at: run.finished_at, at_odds: summary.at_odds}
    end
  end

  # The one thing that moves by the second: the run in flight. Only ever zero or
  # one, because the mirror runs one sync at a time.
  defp assign_progress(socket) do
    # A "running" run whose node is gone would otherwise sit at the top of this
    # table forever. The check is one advisory-lock probe while a sync runs and
    # one indexed select while none does.
    Sync.abandon_abandoned_runs()

    running =
      Repo.one(
        from r in SyncRun,
          where: r.status == "running",
          order_by: [desc: r.started_at],
          limit: 1
      )

    assign(socket, running: running, progress: progress(running))
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
      page_title="Admin"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:overview} />
      </:subnav>

      <.admin_header
        title="Overview"
        subtitle="Freshness, sync runs and recent activity. The sync and audit logs keep the detail."
      >
        <:actions>
          <button
            type="button"
            phx-click="snapshot"
            phx-disable-with="Queueing…"
            class="btn btn-primary btn-sm gap-1.5"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Sync now
          </button>
          <%!-- The same shape as the search screen's filter menus: the button
          opens a panel whose find box takes the keyboard, and the list is
          narrowed in the database, not in the browser. --%>
          <div
            :if={@spaces != []}
            id="sync-space-menu"
            class={[
              "dropdown dropdown-end",
              if(@open_menu == "sync-space", do: "dropdown-open", else: "dropdown-close")
            ]}
            phx-click-away={@open_menu == "sync-space" && "close_menu"}
            phx-window-keydown={@open_menu == "sync-space" && "close_menu"}
            phx-key="Escape"
          >
            <button
              type="button"
              phx-click="toggle_menu"
              phx-value-menu="sync-space"
              aria-expanded={@open_menu == "sync-space"}
              aria-haspopup="true"
              class="btn btn-outline btn-sm gap-1.5"
            >
              Sync one space <.icon name="hero-chevron-down" class="size-3 opacity-40" />
            </button>
            <div
              :if={@open_menu == "sync-space"}
              id="sync-space-panel"
              class="dropdown-content z-50 w-72 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
            >
              <.searchable_select
                id="sync-space"
                name="space"
                query={@space_query}
                options={space_options(@sync_spaces)}
                placeholder="Find a space"
                empty="No space matches"
                change_event="space_query"
                submit_event="space_query"
                select_event="sync_space"
                value_param="key"
                pending="Queueing…"
              />
              <p :if={@sync_spaces_more?} class="mt-1 px-1 text-[11px] text-base-content/70">
                More spaces match — type more of the name, or <a
                  href={~p"/admin/spaces?q=#{@space_query}"}
                  class="link"
                >see them all</a>.
              </p>
            </div>
          </div>
          <a :if={admin_dashboard?()} href="/admin/runtime" class="link text-xs">LiveDashboard</a>
          <%!-- The whole mirror as one folder of files. It comes last and
          behind a divider because it is not a sync: it reads what is already
          mirrored and asks the server for nothing but the bytes. --%>
          <span aria-hidden="true" class="mx-1 h-6 w-px bg-base-300/70"></span>
          <a
            href="/admin/export/site.zip"
            id="export-site"
            class="btn btn-outline btn-sm gap-1.5"
            title={export_hint()}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Static site
          </a>
        </:actions>
      </.admin_header>

      <.job_notice
        :if={@queued}
        job={@queued.job}
        what={@queued.what}
        id="dashboard-job-queued"
      />

      <%!-- Paused is not an error, and it is not invisible either: nothing is
      being read from the site, so every number below is as old as the last
      run. The way out is one click. --%>
      <div
        :if={@paused?}
        id="sync-paused"
        class="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-lg bg-warning/15 px-3 py-2 text-xs"
      >
        <span class="max-w-3xl">
          <span class="font-medium">Confluence calls are paused.</span>
          Runs are refused, queued jobs wait, and reader pages keep serving what was mirrored
          before the pause — so the numbers here are as old as the last run.
        </span>
        <a href={~p"/admin/settings"} class="link shrink-0">Resume in Settings</a>
      </div>

      <p
        :if={Source.demo?(@mirror_source)}
        class="mt-4 max-w-3xl rounded-lg bg-warning/15 px-3 py-2 text-[11px] text-base-content/70"
      >
        Demo data: this mirror reads a sample snapshot bundled with the application, so nothing here was mirrored from a real Confluence site. Set
        <code>CM_SOURCE=http</code>
        with site and token settings to mirror a live one.
      </p>

      <%!-- A run in flight is the one thing an operator watches, and a run is
      long: the numbers below are re-read every five seconds, so they move. --%>
      <section
        :if={@progress}
        id="sync-progress"
        class="mt-4 rounded-xl border border-primary/30 bg-primary/5 px-4 py-3"
      >
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class="loading loading-spinner loading-xs text-primary"></span>
          <h2 class="text-sm font-semibold">Syncing now</h2>
          <span id="sync-phase" class="badge badge-primary badge-xs badge-outline">
            {@progress.phase}
          </span>
          <span class="text-[11px] text-base-content/70">
            {@progress.mode} sync, started by {@progress.trigger}, running for {@progress.running_for}
          </span>
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-x-5 gap-y-1">
          <.stat label="Pages" value={@progress.pages} icon="hero-document-text" />
          <.stat label="Calls" value={@progress.requests} icon="hero-bolt" />
          <.stat label="Data" value={human_bytes(@progress.bytes)} icon="hero-circle-stack" />
          <.stat label="Retries" value={@progress.retries} icon="hero-arrow-path" />
          <.stat
            :if={@progress.failed > 0}
            label="Failed"
            value={@progress.failed}
            icon="hero-exclamation-triangle"
          />
          <.stat label="Pace" value={@progress.pace} icon="hero-clock" />
        </div>
      </section>

      <%!-- Four numbers, one strip: they are read together, and a tile each buys
      nothing but height. One line from `sm` up, two columns on a phone. --%>
      <section
        id="overview-stats"
        class="mt-4 grid grid-cols-2 gap-x-4 gap-y-1 rounded-xl border border-base-300/70 bg-base-100 px-3 py-2 sm:mt-5 sm:flex sm:flex-wrap sm:items-center sm:gap-x-5 sm:px-4"
      >
        <.stat label="Pages" value={@stats.pages} icon="hero-document-text">
          <:hint :if={@upstream && @upstream.named > 0}>
            {pages_hint(@stats.pages, @upstream)}
          </:hint>
        </.stat>
        <.stat label="Attachments" value={@stats.attachments} icon="hero-paper-clip" />
        <.stat label="Labels" value={@stats.labels} icon="hero-tag" />
        <.stat
          label="Freshness"
          value={
            if @last_sync,
              do: Time.ago(@last_sync.finished_at || @last_sync.started_at),
              else: "never"
          }
          icon="hero-arrow-path"
        >
          <:hint :if={@last_sync}>
            <.local_time at={@last_sync.finished_at} />
          </:hint>
        </.stat>
      </section>

      <%!-- What the box costs: the mount the attachments live on, the room left
      on that device, and the database behind it. A deployment usually keeps the
      database on another machine, so it is a figure rather than a share. --%>
      <.section
        id="resources"
        title="Resources"
        subtitle="What this node occupies, and the room left beside it."
      >
        <:actions>
          <%!-- This strip is the point-in-time view, mirror-specific figures
          included (the blob mount, the database). The BEAM's own dashboard has
          the same OS numbers as graphs with history, when the deployment mounts
          it; its memory figure counts *free*, ours counts *available*. --%>
          <a
            :if={admin_dashboard?()}
            href="/admin/runtime/os_mon"
            id="resources-os-data"
            title="CPU load, memory and every mount, with history — LiveDashboard's OS Data page"
            class="link text-xs"
          >
            CPU and memory graphs →
          </a>
        </:actions>
        <div class="grid gap-3 sm:grid-cols-3">
          <.resource_meter
            id="resources-blob-mount"
            label="Data mount"
            value={@resources.used_bytes}
            percent={@resources.device && @resources.device.percent}
            share={
              @resources.device && share_percent(@resources.used_bytes, @resources.device.total_bytes)
            }
            detail={device_line(@resources)}
            note={"#{@resources.files} files, measured #{Time.ago(@resources.measured_at)}"}
            hint={@resources.path}
          />
          <.resource_meter
            id="resources-database"
            label="Postgres"
            value={@database.bytes}
            percent={database_percent(@database, @database_capacity)}
            share={share_percent(@database.bytes, @database_capacity)}
            detail={database_line(@database, @database_capacity)}
            note={table_line(@database.tables)}
            hint="size from Postgres itself; a percentage needs CM_DATABASE_CAPACITY_GB"
          />
          <.resource_meter
            id="resources-memory"
            label="Memory"
            value={@memory.used_bytes}
            percent={@memory.percent}
            share={share_percent(@memory.beam_bytes, @memory.total_bytes)}
            detail={memory_line(@memory)}
            note={"this VM: #{human_bytes(@memory.beam_bytes)}"}
            hint="the machine's memory, and the part of it this node holds"
          />
          <%!-- memsup samples on its own schedule; before its first sample there
          is a figure nobody should invent. --%>
          <p
            :if={is_nil(@memory)}
            id="resources-memory"
            class="rounded-lg border border-base-300/70 bg-base-100 px-3 py-2 text-[11px] text-base-content/60"
          >
            Memory: the system has not reported it yet.
          </p>
        </div>
      </.section>

      <.section title="Sync runs">
        <:actions>
          <%!-- The table is a window of eight; the database keeps every run.
          These two links are the way out of the window: a file the spreadsheet
          opens, and the same history as JSON lines for a script. Both stream
          from Postgres as the file downloads, so a hundred thousand runs cost
          a batch of memory, not a hundred thousand rows. --%>
          <a
            id="sync-runs-export-csv"
            href={~p"/admin/sync-runs/export?format=csv"}
            title="Download every sync run as CSV, streamed from the database"
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> All runs (CSV)
          </a>
          <a
            id="sync-runs-export-jsonl"
            href={~p"/admin/sync-runs/export?format=jsonl"}
            title="Every sync run as JSON lines — one run per line, for a script"
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> JSONL
          </a>
        </:actions>
        <.data_table id="sync-runs" rows={@rows}>
          <:head>
            <th title="The run's number: the id the audit log and the API name">Run</th>
            <th>When</th>
            <th title="How the run was asked for, and by whom">Mode</th>
            <th title="What the run covered: the whole site, one space or one page">Scope</th>
            <th>Status</th>
            <th>Duration</th>
            <th title="What the site listed for this run's window — not the mirror's size">
              Listed
            </th>
            <th title="Of those, the ones that had to be fetched and rendered">Changed</th>
            <th title="Of those, the ones already up to date and not fetched again">Unchanged</th>
            <th title="How many pages the mirror held when the run finished — the size the three numbers to its left are a slice of">
              In mirror
            </th>
            <th>Attachments</th>
            <th>Errors</th>
            <th><span class="sr-only">Queue</span></th>
          </:head>
          <:row :let={row}>
            <td class="text-xs tabular-nums text-base-content/70">{row.run_id || "—"}</td>
            <td class="whitespace-nowrap text-xs">
              <.local_time at={row.at}>{Time.ago(row.at)}</.local_time>
            </td>
            <td class="text-xs">
              {row.mode}
              <%!-- A mode alone can read as a contradiction: the one-page runs are
              stored as "webhook", and one of them asked for on the command line
              would look like a delivery. The trigger beside it says who asked. --%>
              <span :if={row.trigger} class="block text-[11px] text-base-content/70">
                {row.trigger}
              </span>
            </td>
            <td class="text-xs" title={row.scope}>{row.scope}</td>
            <td><span class={["badge badge-sm", status_class(row.status)]}>{row.status}</span></td>
            <td class="text-xs tabular-nums">{row.duration}</td>
            <td class="text-xs tabular-nums">{row.listed}</td>
            <td class="text-xs tabular-nums">{row.changed}</td>
            <td class="text-xs tabular-nums">{row.unchanged}</td>
            <td class="text-xs tabular-nums">{row.total}</td>
            <td class="text-xs tabular-nums">{row.attachments}</td>
            <td class="max-w-[18rem] truncate text-xs text-error" title={row.error}>
              {row.error || "—"}
            </td>
            <td class="text-right">
              <%!-- Both actions sit in the row they act on: a run in flight is
              stopped, a job that has not started is dropped. --%>
              <button
                :if={row.status == "running"}
                type="button"
                id={"cancel-sync-#{row.run_id}"}
                phx-click="cancel_sync"
                phx-value-run_id={row.run_id}
                phx-disable-with="Stopping…"
                data-confirm={
                  "Stop this run now?\n\n" <>
                    "The page it is on is one transaction and rolls back; the pages already " <>
                    "written stay. Nothing is deleted, and the next sync starts where this one stopped."
                }
                title="Stop this run now: the page in flight rolls back and the pages already written stay"
                class="btn btn-warning btn-outline btn-xs gap-1"
              >
                <.icon name="hero-stop" class="size-4" /> Cancel
              </button>
              <%!-- Only a sync that has not started can be dropped: once it is a
              run, stopping it means exiting its process, which is the button
              beside this one. --%>
              <button
                :if={row.job_id}
                type="button"
                id={"cancel-queued-#{row.job_id}"}
                phx-click="cancel_queued"
                phx-value-id={row.job_id}
                phx-disable-with="Dropping…"
                title="Drop this sync from the queue: it will not run"
                class="btn btn-ghost btn-xs gap-1"
              >
                <.icon name="hero-x-mark" class="size-4" /> Drop
              </button>
            </td>
          </:row>
          <:empty>No sync runs yet.</:empty>
        </.data_table>
      </.section>

      <%!-- A re-read is the one button on this page that costs what the first
      sync cost: every page and attachment fetched and rendered again, changed
      or not. So it is not in the row of everyday actions, where "Sync now"
      fetches only what changed — it sits under the runs table, in a sentence
      that says what it spends, and it asks before it queues. --%>
      <div
        id="full-reread"
        class="mt-3 flex flex-wrap items-baseline gap-x-3 gap-y-1.5 rounded-lg border border-base-300/60 px-3 py-2"
      >
        <p class="max-w-2xl text-xs text-base-content/70">
          <span class="font-medium text-base-content/80">Re-reading everything</span>
          fetches and re-renders every page and attachment, changed or not, at the
          sync's configured pace: hours on a large site, and the busiest this mirror
          will ever be with Confluence. Readers keep the pages they already have.
        </p>
        <button
          type="button"
          id="full-sync"
          phx-click="full_sync"
          phx-disable-with="Queueing…"
          class="btn btn-ghost btn-xs gap-1.5"
          data-confirm={
            "Re-read every page and attachment, changed or not?\n\n" <>
              "This is the slowest sync there is: on a large site it runs for hours " <>
              "and keeps Confluence busy the whole time. It goes space by space, " <>
              "so a restart costs one space rather than the whole sweep. Nobody " <>
              "loses access meanwhile.\n\nQueue it?"
          }
        >
          <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Re-read everything
        </button>
      </div>

      <div class="mt-8 grid gap-6 xl:grid-cols-2">
        <.section title="Latest activity" class="mt-0">
          <:actions>
            <.link navigate={~p"/admin/audit"} class="link link-primary text-xs">
              Open the audit log →
            </.link>
          </:actions>
          <ul class="divide-y divide-base-300/60">
            <li :for={event <- @audit} class="flex items-baseline gap-3 py-2 text-xs">
              <span class="w-20 shrink-0 text-[11px] text-base-content/70">
                {Time.ago(event.inserted_at)}
              </span>
              <span class="min-w-0 flex-1 truncate">
                <span class="font-mono text-[11px] uppercase tracking-wide text-base-content/70">
                  {event.action}
                </span>
                <span class="ml-2 text-base-content/70">{event.actor_label || event.actor_type}</span>
              </span>
            </li>
            <li :if={@audit == []} class="py-2 text-xs text-base-content/70">
              Nothing has happened yet.
            </li>
          </ul>
        </.section>

        <.section title="Recently updated" class="mt-0">
          <:actions>
            <a href={~p"/recent"} class="link link-primary text-xs">All recent →</a>
          </:actions>
          <ul class="divide-y divide-base-300/60">
            <li :for={page <- @recent_pages} class="py-1.5">
              <.link
                navigate={
                  ConfluencePhxMirror.Mirror.URLs.page_path(
                    page.space.key,
                    page.confluence_id,
                    page.slug
                  )
                }
                class="flex items-baseline gap-2 text-xs hover:text-primary"
              >
                <span class="badge badge-ghost badge-xs">{page.space.key}</span>
                <span class="min-w-0 flex-1 truncate">{page.title}</span>
                <span class="shrink-0 text-[11px] text-base-content/70">
                  {Time.ago(page.external_updated_at)}
                </span>
              </.link>
            </li>
            <li :if={@recent_pages == []} class="py-2 text-xs text-base-content/70">
              Nothing mirrored yet.
            </li>
          </ul>
        </.section>
      </div>
    </Layouts.app>
    """
  end

  defp admin_dashboard? do
    Application.get_env(:confluence_phx_mirror, :admin_dashboard, false)
  end

  # What the download holds, according to the policy in force — the same
  # setting `Export.site_archive/2` reads, so the sentence cannot claim a policy
  # the archive does not follow.
  defp export_hint do
    if Settings.export_personal_spaces?() do
      "Every space, page and attachment as a static site, personal spaces included (an administrator turned that on)"
    else
      "Every shared space, page and attachment as a static site — personal spaces are left out (an administrator can include them)"
    end
  end

  # One list in the order an operator waits through it: what is queued, then
  # what already ran. Both kinds share a row shape, because a queued sync is a
  # line in the same table — with a button of its own — not a separate one.
  defp sync_rows(queued, runs) do
    Enum.map(queued, &queued_row/1) ++ Enum.map(runs, &run_row/1)
  end

  # Nothing has happened yet on a queued row, so the outcome columns say so
  # rather than claim a zero.
  defp queued_row(job) do
    %{
      run_id: nil,
      at: job.inserted_at,
      mode: job_mode(job),
      trigger: Map.get(job.args, "trigger"),
      scope: job_scope(job),
      status: queued_status(job.state),
      duration: "—",
      listed: "—",
      changed: "—",
      unchanged: "—",
      total: "—",
      attachments: "—",
      error: nil,
      job_id: job.id,
      dom_id: "queued-#{job.id}"
    }
  end

  defp run_row(run) do
    # The same numbers the audit entry records — one function, so the table and
    # the log cannot disagree about what a run did.
    numbers = SyncRun.summary(run)

    %{
      run_id: run.id,
      at: run.started_at,
      mode: run.mode,
      # Who asked, when the run was asked for by someone: written at the start
      # and kept through the numbers that replace the run's stats.
      trigger: Map.get(run.stats || %{}, "trigger"),
      # Runs recorded before the scope column existed only have their mode; a
      # snapshot or an incremental pull of that age was always the whole site.
      scope: run.scope || scope_from_mode(run.mode),
      status: run.status,
      duration: Time.duration(run.started_at, run.finished_at),
      # What the site listed for this run's window, and of those, what had to be
      # fetched and what was already up to date. A run's numbers are its window,
      # not the mirror: the mirror's size is `Mirror.stats/0`, printed above.
      listed: numbers.listed,
      changed: numbers.changed,
      unchanged: numbers.unchanged,
      total: numbers.in_mirror,
      attachments: numbers.attachments,
      error: run.error,
      job_id: nil,
      dom_id: "sync-run-#{run.id}"
    }
  end

  # `mode` says how the job was asked for; `scope` says what it will touch, and
  # the two are separate columns so a finished run reads like a queued one.
  defp job_mode(%Oban.Job{worker: worker, args: args}) do
    cond do
      worker == inspect(SnapshotWorker) ->
        if args["mode"] == "snapshot", do: "snapshot", else: "incremental"

      worker == inspect(SpaceWorker) ->
        "incremental"

      worker == inspect(PageWorker) ->
        "webhook"

      true ->
        "sync"
    end
  end

  defp job_scope(%Oban.Job{args: args}) do
    cond do
      args["space_key"] -> "space #{args["space_key"]}"
      args["confluence_id"] -> "page #{args["confluence_id"]}"
      true -> "whole site"
    end
  end

  defp scope_from_mode("webhook"), do: "one page"
  defp scope_from_mode(_whole_site_or_incremental), do: "whole site"

  # Oban's own states are scheduling vocabulary ("available" means "waiting for
  # a free slot", "retryable" means "waiting for the next attempt"); the table
  # says what is true for the reader.
  defp queued_status("available"), do: "queued"
  defp queued_status("retryable"), do: "retrying"
  defp queued_status(state), do: state

  defp status_class("succeeded"), do: "badge-success"
  defp status_class("partial"), do: "badge-warning"
  defp status_class("failed"), do: "badge-error"
  defp status_class("cancelled"), do: "badge-neutral"
  defp status_class("running"), do: "badge-info"
  defp status_class("retrying"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"
end
