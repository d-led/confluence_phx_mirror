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

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirrorWeb.Plugs.WebhookRateLimit
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

  # The switches live here rather than on the settings page because this is the
  # page that shows what an unauthenticated intake costs.
  @impl true
  def handle_event("require_signatures", _params, socket) do
    Settings.put_webhook_require_signature(true, actor(socket))

    {:noreply, socket |> put_flash(:info, "Webhook signatures are now required.") |> load()}
  end

  def handle_event("allow_unsigned", _params, socket) do
    Settings.put_webhook_require_signature(false, actor(socket))

    {:noreply,
     socket
     |> put_flash(:info, "Unsigned deliveries are accepted again.")
     |> load()}
  end

  def handle_event("use_configured_signatures", _params, socket) do
    Settings.put_webhook_require_signature(nil, actor(socket))

    {:noreply,
     socket
     |> put_flash(:info, "Signatures follow the deployment setting again.")
     |> load()}
  end

  def handle_event("set_intake_limit", %{"limit" => value}, socket) do
    case Integer.parse(String.trim(to_string(value))) do
      {per_minute, ""} when per_minute > 0 ->
        Settings.put_webhook_rate_limit(per_minute, actor(socket))

        {:noreply,
         socket
         |> put_flash(:info, "The intake now allows #{per_minute} deliveries a minute.")
         |> load()}

      _other ->
        {:noreply, put_flash(socket, :error, "The cap must be a whole number above zero.")}
    end
  end

  def handle_event("reset_intake_limit", _params, socket) do
    Settings.put_webhook_rate_limit(nil, actor(socket))

    {:noreply,
     socket
     |> put_flash(:info, "The intake cap follows the deployment setting again.")
     |> load()}
  end

  defp actor(%{assigns: %{current_user: user}}), do: {:user, user}

  defp load(socket) do
    config = Application.get_env(:confluence_phx_mirror, :webhooks, [])
    tokens = Application.get_env(:confluence_phx_mirror, :webhook_tokens, %{})
    {intake_limit, _period_ms} = WebhookRateLimit.config()

    assign(socket,
      deliveries: Webhooks.recent(@deliveries),
      secret?: is_binary(config[:secret]),
      receivers: map_size(tokens),
      signature_required?: Webhooks.signature_required?(),
      signature_by_admin?: Settings.webhook_require_signature() != nil,
      intake_limit: intake_limit,
      intake_by_admin?: Settings.webhook_rate_limit() != nil
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
        No <code>CM_WEBHOOK_SECRET</code> is configured, so signatures cannot be checked. Point
        Confluence at <code>/webhooks/confluence</code> and give both sides the same secret.
      </div>

      <div
        :if={not @signature_required?}
        id="webhook-unsigned-warning"
        role="alert"
        class="mt-4 rounded-xl border-2 border-error/60 bg-error/10 p-4"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-6 shrink-0 text-error" />
          <div class="min-w-0">
            <p class="text-sm font-semibold text-error">
              This intake trusts anyone who can reach it
            </p>
            <p class="mt-1 text-xs text-base-content/80">
              A delivery without a valid signature or token is acted on as it arrives: whoever can
              reach <code class="font-mono">/webhooks/confluence</code> can make this mirror sync a
              page or mark one deleted. Each one is still recorded, and the intake stays capped at {@intake_limit} deliveries a minute per address.
            </p>
            <p class="mt-2 text-xs text-base-content/70">
              To close it, give the mirror the secret Confluence signs with
              (<code class="font-mono">CM_WEBHOOK_SECRET</code>) and require signatures — here, or
              with <code class="font-mono">CM_WEBHOOK_REQUIRE_SIGNATURE=true</code>.
            </p>
            <button
              :if={@secret?}
              id="webhook-require-signatures"
              type="button"
              phx-click="require_signatures"
              class="btn btn-error btn-sm mt-3"
            >
              Require signatures
            </button>
            <p :if={not @secret?} class="mt-2 text-[11px] font-medium text-error">
              Requiring signatures before a secret exists would refuse every delivery.
            </p>
          </div>
        </div>
      </div>

      <dl class="mt-4 flex flex-wrap gap-x-8 gap-y-2 text-xs">
        <div class="flex items-baseline gap-2">
          <dt class="text-base-content/70">Endpoint</dt>
          <dd class="font-mono">/webhooks/confluence</dd>
        </div>
        <div class="flex items-baseline gap-2">
          <dt class="text-base-content/70">Signature</dt>
          <dd id="webhook-signature-state">
            {if @signature_required?, do: "required, or a token", else: "not required"}
            <span :if={@signature_by_admin?} class="text-base-content/60">· set here</span>
          </dd>
        </div>
        <div class="flex items-baseline gap-2">
          <dt class="text-base-content/70">Fixed tokens</dt>
          <dd>{if @receivers > 0, do: "#{@receivers} receiver(s)", else: "none"}</dd>
        </div>
      </dl>

      <section
        id="webhook-controls"
        class="mt-4 grid gap-4 rounded-xl border border-base-300/70 bg-base-100 p-4 sm:grid-cols-2"
      >
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-wider text-base-content/70">
            Signatures
          </p>
          <p class="mt-1 text-sm font-medium">
            {if @signature_required?, do: "required", else: "not required"}
          </p>
          <p class="mt-0.5 text-[11px] text-base-content/70">
            {if @signature_by_admin?,
              do: "set on this page, overrides the deployment",
              else: "from the deployment (CM_WEBHOOK_REQUIRE_SIGNATURE)"}
          </p>
          <div class="mt-2 flex flex-wrap gap-2">
            <button
              :if={not @signature_required? and @secret?}
              type="button"
              phx-click="require_signatures"
              class="btn btn-sm btn-error"
            >
              Require
            </button>
            <button
              :if={@signature_required?}
              type="button"
              phx-click="allow_unsigned"
              data-confirm="Anyone who can reach the endpoint will be able to trigger syncs and deletions. Continue?"
              class="btn btn-sm btn-ghost"
            >
              Allow unsigned
            </button>
            <button
              :if={@signature_by_admin?}
              type="button"
              phx-click="use_configured_signatures"
              class="btn btn-sm btn-ghost"
            >
              Use the deployment setting
            </button>
          </div>
        </div>

        <div>
          <p class="text-[11px] font-semibold uppercase tracking-wider text-base-content/70">
            Intake cap
          </p>
          <p class="mt-1 text-sm font-medium">{@intake_limit} deliveries a minute</p>
          <p class="mt-0.5 text-[11px] text-base-content/70">
            {if @intake_by_admin?,
              do: "set on this page, overrides the deployment",
              else: "from the deployment (CM_WEBHOOK_RATE_LIMIT_PER_MINUTE)"}
          </p>
          <form
            id="webhook-intake-form"
            phx-submit="set_intake_limit"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <input
              type="number"
              name="limit"
              min="1"
              value={@intake_limit}
              aria-label="Deliveries a minute"
              class="input input-sm w-24 rounded-lg"
            />
            <button type="submit" class="btn btn-sm btn-ghost">Save</button>
            <button
              :if={@intake_by_admin?}
              type="button"
              phx-click="reset_intake_limit"
              class="btn btn-sm btn-ghost"
            >
              Use the deployment setting
            </button>
          </form>
        </div>
      </section>

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
