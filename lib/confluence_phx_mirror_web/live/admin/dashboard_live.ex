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
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.{SnapshotWorker, SpaceWorker}
  alias ConfluencePhxMirror.Sync.SyncRun
  alias ConfluencePhxMirrorWeb.Plugs
  alias ConfluencePhxMirrorWeb.Time

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok, assign(socket, page_title: "Overview") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("snapshot", _params, socket) do
    %{"trigger" => requested_by(socket)}
    |> SnapshotWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Sync queued. Runs appear below within seconds.")}
  end

  def handle_event("full_sync", _params, socket) do
    %{"trigger" => "#{requested_by(socket)}, re-reading everything", "mode" => "snapshot"}
    |> SnapshotWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Full re-read queued: every page will be fetched again.")}
  end

  def handle_event("sync_space", %{"key" => key}, socket) do
    %{"space_key" => key, "trigger" => requested_by(socket)}
    |> SpaceWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Space #{key} queued for refresh.")}
  end

  # The audit log answers "who asked for this?" for every run, so a manual one
  # carries the address of the admin who pressed the button.
  defp requested_by(socket) do
    case socket.assigns[:current_user] do
      nil -> "the admin dashboard"
      user -> "the admin dashboard, by #{user.email}"
    end
  end

  defp load(socket) do
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
      space_counts: Mirror.spaces_with_counts(),
      runs: runs,
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
          <details :if={@spaces != []} class="dropdown dropdown-end">
            <summary class="btn btn-outline btn-sm">Sync one space</summary>
            <ul class="menu dropdown-content z-50 mt-2 w-52 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
              <li :for={{space, _count} <- @space_counts}>
                <button
                  type="button"
                  phx-click="sync_space"
                  phx-value-key={space.key}
                  phx-disable-with="Queueing…"
                >
                  {space.name} <span class="badge badge-ghost badge-xs">{space.key}</span>
                </button>
              </li>
            </ul>
          </details>
          <button
            type="button"
            phx-click="full_sync"
            phx-disable-with="Queueing…"
            class="btn btn-ghost btn-sm gap-1.5"
            title="Fetch and re-render every page, even the ones that did not change"
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Re-read everything
          </button>
          <a :if={dev_routes?()} href="/dev/dashboard" class="link text-xs">LiveDashboard</a>
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

      <%!-- One column of rows on a phone, four tiles from `sm` up. --%>
      <section class="mt-6 grid grid-cols-1 divide-y divide-base-300/60 rounded-xl border border-base-300/70 bg-base-100 px-3 sm:grid-cols-2 sm:divide-y-0 sm:gap-3 sm:rounded-none sm:border-0 sm:bg-transparent sm:px-0 lg:grid-cols-4">
        <.stat_card label="Pages" value={@stats.pages} icon="hero-document-text" />
        <.stat_card label="Attachments" value={@stats.attachments} icon="hero-paper-clip" />
        <.stat_card label="Labels" value={@stats.labels} icon="hero-tag" />
        <.stat_card
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
        </.stat_card>
      </section>

      <.section title="Sync runs">
        <.data_table id="sync-runs" rows={@runs}>
          <:head>
            <th>Started</th>
            <th>Mode</th>
            <th>Status</th>
            <th>Duration</th>
            <th>Pages</th>
            <th>Attachments</th>
            <th>Errors</th>
          </:head>
          <:row :let={run}>
            <td class="whitespace-nowrap text-xs" title={Time.datetime(run.started_at)}>
              {Time.ago(run.started_at)}
            </td>
            <td class="text-xs">{run.mode}</td>
            <td><span class={["badge badge-sm", status_class(run.status)]}>{run.status}</span></td>
            <td class="text-xs tabular-nums">{Time.duration(run.started_at, run.finished_at)}</td>
            <td class="text-xs tabular-nums">{run.stats["pages"] || 0}</td>
            <td class="text-xs tabular-nums">{run.stats["attachments"] || 0}</td>
            <td class="max-w-[18rem] truncate text-xs text-error" title={run.error}>
              {run.error || "—"}
            </td>
          </:row>
          <:empty>No sync runs yet.</:empty>
        </.data_table>
      </.section>

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

  defp dev_routes? do
    Application.get_env(:confluence_phx_mirror, :dev_routes, false)
  end

  defp status_class("succeeded"), do: "badge-success"
  defp status_class("partial"), do: "badge-warning"
  defp status_class("failed"), do: "badge-error"
  defp status_class("running"), do: "badge-info"
  defp status_class(_), do: "badge-ghost"
end
