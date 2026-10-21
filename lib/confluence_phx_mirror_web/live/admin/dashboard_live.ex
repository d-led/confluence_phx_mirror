defmodule ConfluencePhxMirrorWeb.Admin.DashboardLive do
  @moduledoc """
  Operator dashboard: freshness, sync runs, audit trail and webhook deliveries,
  plus the actions an operator needs during a demo or an incident.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import Ecto.Query
  import ConfluencePhxMirrorWeb.UIComponents

  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Audit
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
    %{} |> SnapshotWorker.new() |> Oban.insert()
    {:noreply, put_flash(socket, :info, "Snapshot queued. Runs appear below within seconds.")}
  end

  def handle_event("sync_space", %{"key" => key}, socket) do
    %{"space_key" => key} |> SpaceWorker.new() |> Oban.insert()
    {:noreply, put_flash(socket, :info, "Space #{key} queued for refresh.")}
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
      mirror_source={@mirror_source}
      page_title="Admin"
      sidebar?={false}
    >
      <header class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300/70 pb-5">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">Operations</p>
          <h1 class="mt-1 text-3xl font-semibold">Mirror dashboard</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Source: <span class="font-medium">{source_name(@mirror_source)}</span>
            · <a href={~p"/admin/users"} class="link link-primary">Users &amp; tokens</a>
            · <a href="/dev/dashboard" class="link link-primary">LiveDashboard</a>
            · <a href="/dev/mailbox" class="link link-primary">Mailbox</a>
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
        <.section title="Audit trail" class="mt-0">
          <.data_table id="audit-events" rows={@audit}>
            <:head>
              <th>When</th><th>Actor</th><th>Action</th><th>Entity</th>
            </:head>
            <:row :let={event}>
              <td class="whitespace-nowrap" title={Time.datetime(event.inserted_at)}>
                {Time.ago(event.inserted_at)}
              </td>
              <td class="max-w-[9rem] truncate">{event.actor_label || event.actor_type}</td>
              <td class="font-mono text-[11px]">{event.action}</td>
              <td class="text-[11px] text-base-content/55">{event.entity_type} #{event.entity_id}</td>
            </:row>
            <:empty>No audit events.</:empty>
          </.data_table>
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

  defp source_name(ConfluencePhxMirror.Confluence.DemoSource), do: "bundled demo snapshot"
  defp source_name(ConfluencePhxMirror.Confluence.HttpSource), do: "Confluence REST API"
  defp source_name(module), do: inspect(module)
end
