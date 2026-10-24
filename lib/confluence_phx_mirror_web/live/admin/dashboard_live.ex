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
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{SnapshotWorker, SpaceWorker}
  alias ConfluencePhxMirror.Sync.SyncRun
  alias ConfluencePhxMirrorWeb.Plugs
  alias ConfluencePhxMirrorWeb.Time

  @refresh_ms 5_000
  # The "sync one space" panel narrows in the database and takes a window: a
  # site with hundreds of spaces should not feel like a list of hundreds.
  @space_window 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     assign(socket,
       page_title: "Overview",
       open_menu: nil,
       space_query: "",
       sync_spaces: spaces_like("")
     )
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

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
    {:noreply, assign(socket, open_menu: nil, space_query: "", sync_spaces: spaces_like(""))}
  end

  defp space_query(%{"space" => query}, socket) do
    {:noreply, assign(socket, space_query: query, sync_spaces: spaces_like(query))}
  end

  defp snapshot(_params, socket) do
    %{"trigger" => requested_by(socket)}
    |> SnapshotWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Sync queued. Runs appear below within seconds.")}
  end

  defp full_sync(_params, socket) do
    %{"trigger" => "#{requested_by(socket)}, re-reading everything", "mode" => "snapshot"}
    |> SnapshotWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Full re-read queued: every page will be fetched again.")}
  end

  defp sync_space(%{"key" => key}, socket) do
    %{"space_key" => key, "trigger" => requested_by(socket)}
    |> SpaceWorker.new()
    |> Oban.insert()

    {:noreply,
     socket
     |> put_flash(:info, "Space #{key} queued for refresh.")
     |> assign(open_menu: nil, space_query: "", sync_spaces: spaces_like(""))}
  end

  # A cancel is a request the run honours between pages, so the answer is
  # "asked", not "stopped": the table shows the status change on the next tick.
  defp cancel_sync(%{"run_id" => run_id}, socket) do
    case Sync.cancel(run_id, {:user, socket.assigns.current_user}) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cancelling: the run stops after the page it is working on.")
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
  # a window of twenty, alphabetical. Nothing is filtered in the browser.
  defp spaces_like(query), do: Mirror.list_spaces(query: query, limit: @space_window)

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

  defp phase_label(nil), do: "talking to the site"
  defp phase_label(phase), do: Map.get(@phases, phase, phase)

  defp human_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human_bytes(bytes) when bytes < 1024 * 1024, do: "#{round(bytes / 1024)} KB"
  defp human_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  # The audit log answers "who asked for this?" for every run, so a manual one
  # carries the address of the admin who pressed the button.
  defp requested_by(socket) do
    case socket.assigns[:current_user] do
      nil -> "the admin dashboard"
      user -> "the admin dashboard, by #{user.email}"
    end
  end

  defp load(socket) do
    # A "running" run whose node is gone would otherwise sit at the top of this
    # table forever. The check is one advisory-lock probe while a sync runs and
    # one indexed select while none does.
    Sync.abandon_abandoned_runs()

    runs =
      Repo.all(
        from r in SyncRun,
          order_by: [desc: r.started_at],
          limit: 8
      )

    assign(socket,
      stats: Mirror.stats(),
      # The shell's switcher draws a window of the directory, so the dashboard
      # sends a window: this reloads every five seconds.
      spaces: Mirror.list_spaces(limit: Plugs.SiteContext.switcher_limit()),
      # Queue and history are one list: what waits is what an operator can still
      # stop, and it reads next to what already ran.
      rows: sync_rows(Sync.queued(), runs),
      # The one the cancel button acts on: only ever zero or one, because the
      # mirror runs one sync at a time.
      running: Enum.find(runs, &(&1.status == "running")),
      progress: progress(Enum.find(runs, &(&1.status == "running"))),
      audit: Audit.recent(18),
      recent_pages: Mirror.recent_pages(8),
      last_sync: Mirror.last_successful_sync_run()
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
      page_title="Admin"
      sidebar?={false}
    >
      <.admin_header
        current={:overview}
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
            </div>
          </div>
          <a :if={admin_dashboard?()} href="/admin/runtime" class="link text-xs">LiveDashboard</a>
        </:actions>
      </.admin_header>

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
        <.stat label="Pages" value={@stats.pages} icon="hero-document-text" />
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

      <.section title="Sync runs">
        <:actions>
          <form
            :if={@running}
            id="cancel-sync-form"
            phx-submit="cancel_sync"
            class="flex items-center gap-1.5"
          >
            <input type="hidden" name="run_id" value={@running.id} />
            <button
              type="submit"
              id="cancel-sync"
              class="btn btn-warning btn-outline btn-sm"
              data-confirm={
                "Stop the sync that started #{Time.ago(@running.started_at)}?\n\n" <>
                  "It finishes the page it is on and stops: #{@running.stats["pages"] || 0} " <>
                  "pages listed so far stay in the mirror. Nothing is deleted, and the next " <>
                  "sync starts from where this one stopped."
              }
            >
              <.icon name="hero-stop" class="size-4" /> Cancel sync
            </button>
          </form>
        </:actions>
        <.data_table id="sync-runs" rows={@rows}>
          <:head>
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
              <%!-- Only a sync that has not started can be dropped: once it is a
              run, stopping it means asking it to stop, which is the button
              above the table. --%>
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
              "and keeps Confluence busy the whole time. Nobody loses access meanwhile, " <>
              "and the run can be cancelled from this page.\n\nQueue it?"
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
