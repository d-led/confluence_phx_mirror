defmodule ConfluencePhxMirrorWeb.Admin.DashboardLive do
  @moduledoc """
  Operator dashboard: freshness, sync runs, recent activity and webhook deliveries,
  plus the actions an operator needs during a demo or an incident.

  The activity list here is a pointer, not the log itself: `/admin/audit` holds
  the full, filterable audit log with every event's details.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import Ecto.Query
  import ConfluencePhxMirrorWeb.UIComponents

  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.{SnapshotWorker, SpaceWorker}
  alias ConfluencePhxMirror.Sync.SyncRun
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirrorWeb.Time

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     assign(socket,
       webhook_secret?:
         is_binary(Application.get_env(:confluence_phx_mirror, :webhooks, [])[:secret])
     )
     |> load()}
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
      spaces: Mirror.list_spaces(),
      space_counts: Mirror.spaces_with_counts(),
      runs: runs,
      audit: Audit.recent(18),
      deliveries: Webhooks.recent(8),
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
      <header class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300/70 pb-5">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">Operations</p>
          <h1 class="mt-1 text-3xl font-semibold">Mirror dashboard</h1>
          <p class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
            <span class="uppercase tracking-[0.14em] text-base-content/40">Mirroring</span>
            <a
              :if={@mirror_url}
              href={@mirror_url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> {@mirror_host}
            </a>
            <span :if={is_nil(@mirror_url)} class="text-sm font-medium">{source_name(@mirror_source)}</span>
          </p>
          <p class="mt-1 text-xs text-base-content/50">
            <a href={~p"/admin/audit"} class="link link-primary">Audit log</a>
            · <a href={~p"/admin/sync-log"} class="link link-primary">Sync log</a>
            · <a href={~p"/admin/users"} class="link link-primary">Users &amp; tokens</a>
            · <a href="/dev/dashboard" class="link link-primary">LiveDashboard</a>
          </p>
          <p
            :if={Source.demo?(@mirror_source)}
            class="mt-2 max-w-2xl rounded-lg bg-warning/15 px-3 py-2 text-[11px] text-base-content/70"
          >
            Demo data: this mirror reads a sample snapshot bundled with the application, so nothing here was mirrored from a real Confluence site. Set
            <code>CM_SOURCE=http</code>
            with site and token settings to mirror a live one.
          </p>
          <p :if={@current_user} class="mt-1 text-[11px] text-base-content/45">
            Signed in as {@current_user.email}
            <span :if={Admins.source(@current_user)} class="badge badge-primary badge-xs">
              admin · {Admins.source(@current_user)}
            </span>
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <button type="button" phx-click="snapshot" class="btn btn-primary btn-sm gap-1.5">
            <.icon name="hero-arrow-path" class="size-4" /> Sync now
          </button>
          <details :if={@spaces != []} class="dropdown dropdown-end">
            <summary class="btn btn-outline btn-sm">Sync one space</summary>
            <ul class="menu dropdown-content z-50 mt-2 w-52 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl">
              <li :for={{space, _count} <- @space_counts}>
                <button type="button" phx-click="sync_space" phx-value-key={space.key}>
                  {space.name} <span class="badge badge-ghost badge-xs">{space.key}</span>
                </button>
              </li>
            </ul>
          </details>
          <button
            type="button"
            phx-click="full_sync"
            class="btn btn-ghost btn-sm gap-1.5"
            title="Fetch and re-render every page, even the ones that did not change"
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Re-read everything
          </button>
        </div>
      </header>

      <section class="mt-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
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
          hint={if @last_sync, do: Time.datetime(@last_sync.finished_at)}
          icon="hero-arrow-path"
        />
      </section>

      <div
        :if={not @webhook_secret?}
        class="mt-4 rounded-xl border border-warning/40 bg-warning/5 p-3 text-xs text-base-content/70"
      >
        Webhooks are <strong>not configured</strong>: set <code>CM_WEBHOOK_SECRET</code>
        and point Confluence at <code>/webhooks/confluence</code>. Deliveries without a valid signature are rejected and audited.
      </div>

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
              <span class="w-20 shrink-0 text-[11px] text-base-content/45">
                {Time.ago(event.inserted_at)}
              </span>
              <span class="min-w-0 flex-1 truncate">
                <span class="font-mono text-[11px] uppercase tracking-wide text-base-content/45">
                  {event.action}
                </span>
                <span class="ml-2 text-base-content/70">{event.actor_label || event.actor_type}</span>
              </span>
            </li>
            <li :if={@audit == []} class="py-2 text-xs text-base-content/50">
              Nothing has happened yet.
            </li>
          </ul>
        </.section>

        <.section title="Webhook deliveries" class="mt-0">
          <.data_table id="webhook-deliveries" rows={@deliveries}>
            <:head>
              <th>When</th><th>Event</th><th>Signature</th><th>Status</th>
            </:head>
            <:row :let={delivery}>
              <td class="whitespace-nowrap" title={Time.datetime(delivery.received_at)}>
                {Time.ago(delivery.received_at)}
              </td>
              <td class="font-mono text-[11px]">{delivery.event_type || "—"}</td>
              <td>
                <span class={[
                  "badge badge-xs",
                  if(delivery.signature_valid, do: "badge-success", else: "badge-error")
                ]}>
                  {if delivery.signature_valid, do: "valid", else: "invalid"}
                </span>
              </td>
              <td class="text-[11px]">{delivery.status}</td>
            </:row>
            <:empty>No deliveries.</:empty>
          </.data_table>
        </.section>
      </div>

      <section class="mt-8">
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Recently updated pages
        </h2>
        <div class="flex flex-wrap gap-2">
          <.link
            :for={page <- @recent_pages}
            navigate={
              ConfluencePhxMirror.Mirror.URLs.page_path(page.space.key, page.confluence_id, page.slug)
            }
            class="inline-flex items-center gap-2 rounded-lg border border-base-300/70 bg-base-100 px-3 py-1.5 text-xs hover:border-primary/40 hover:text-primary"
          >
            <span class="badge badge-ghost badge-xs">{page.space.key}</span>
            <span class="max-w-[20rem] truncate">{page.title}</span>
            <span class="text-[10px] text-base-content/40">{Time.ago(page.external_updated_at)}</span>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp status_class("succeeded"), do: "badge-success"
  defp status_class("partial"), do: "badge-warning"
  defp status_class("failed"), do: "badge-error"
  defp status_class("running"), do: "badge-info"
  defp status_class(_), do: "badge-ghost"

  defp source_name(module) do
    case Source.kind(module) do
      :demo -> "bundled demo snapshot — demo data, not a mirrored site"
      :live -> "Confluence REST API"
    end
  end
end
