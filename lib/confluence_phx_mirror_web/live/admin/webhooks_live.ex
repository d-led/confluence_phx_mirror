defmodule ConfluencePhxMirrorWeb.Admin.WebhooksLive do
  @moduledoc """
  What Confluence sent, and whether it could be trusted.

  Deliveries are stored before their signature is checked, so a rejected event
  is visible here too — that is how an operator tells "Confluence is not
  calling" apart from "the secret is wrong". The page refreshes itself, because
  a delivery arrives without anything else on the page changing.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.UIComponents
  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirrorWeb.Time

  @refresh_ms 5_000
  @deliveries 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok, assign(socket, page_title: "Webhooks") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    config = Application.get_env(:confluence_phx_mirror, :webhooks, [])
    tokens = Application.get_env(:confluence_phx_mirror, :webhook_tokens, %{})

    assign(socket,
      deliveries: Webhooks.recent(@deliveries),
      secret?: is_binary(config[:secret]),
      receivers: map_size(tokens)
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
      page_title="Webhooks"
      sidebar?={false}
    >
      <.admin_header
        current={:webhooks}
        title="Webhooks"
        subtitle="What Confluence sent, and whether it could be trusted."
      />

      <div
        :if={not @secret?}
        class="mt-4 rounded-xl border border-warning/40 bg-warning/5 p-3 text-xs text-base-content/70"
      >
        Webhooks are <strong>not configured</strong>: set <code>CM_WEBHOOK_SECRET</code>
        and point Confluence at <code>/webhooks/confluence</code>. Deliveries without a valid
        signature are rejected and audited.
      </div>

      <dl class="mt-4 flex flex-wrap gap-x-8 gap-y-2 text-xs">
        <div class="flex items-baseline gap-2">
          <dt class="text-base-content/70">Endpoint</dt>
          <dd class="font-mono">/webhooks/confluence</dd>
        </div>
        <div class="flex items-baseline gap-2">
          <dt class="text-base-content/70">Signature</dt>
          <dd>required, or a token instead</dd>
        </div>
        <div class="flex items-baseline gap-2">
          <dt class="text-base-content/70">Fixed tokens</dt>
          <dd>{if @receivers > 0, do: "#{@receivers} receiver(s)", else: "none"}</dd>
        </div>
      </dl>

      <section class="mt-5">
        <.data_table id="webhook-deliveries" rows={@deliveries}>
          <:head>
            <th>Received</th>
            <th>Event</th>
            <th>Signature</th>
            <th>Status</th>
          </:head>
          <:card :let={delivery}>
            <div class="flex items-center justify-between gap-2">
              <span class="font-mono text-[11px] uppercase tracking-wide">
                {delivery.event_type || "—"}
              </span>
              <span class={[
                "badge badge-xs",
                if(delivery.signature_valid, do: "badge-success", else: "badge-error")
              ]}>
                {if delivery.signature_valid, do: "valid", else: "invalid"}
              </span>
            </div>
            <p class="mt-1 text-xs text-base-content/70">
              {Time.ago(delivery.received_at)} · {delivery.status}
            </p>
          </:card>
          <:row :let={delivery}>
            <td class="whitespace-nowrap">
              <.local_time at={delivery.received_at}>{Time.ago(delivery.received_at)}</.local_time>
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
          <:empty>No deliveries yet.</:empty>
        </.data_table>
      </section>
    </Layouts.app>
    """
  end
end
