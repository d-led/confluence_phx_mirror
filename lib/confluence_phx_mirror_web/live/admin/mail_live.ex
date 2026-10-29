defmodule ConfluencePhxMirrorWeb.Admin.MailLive do
  @moduledoc """
  The mail queue: what is waiting to leave the mirror, and the two decisions an
  administrator makes about it.

  Delivery has three states and this screen shows all of them — waiting, refused
  by the relay, delivered — because the question after a wrong relay is not
  "did anything go out" but "what is still in there, and what did it say when it
  failed". The queue is the outbox (`notifications`) rather than Oban's rows:
  those say a job exists, this says which message it carries.

  **Pause** stops the drain without losing a message: both workers snooze, the
  rows stay where they are, and a resume sends what was waiting. Sign-in links
  are not queued and keep working — a pause that locked readers out would be a
  foot-gun, not a switch.

  **Purge** drops everything that has not been delivered and cancels the jobs
  that would have sent it. Delivered rows are the history and stay, which is why
  the foot of the page counts them.

  The page refreshes itself while open: a sync writes to this queue, so the
  numbers move without anyone touching the screen.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.{Notifications, Settings}
  alias ConfluencePhxMirrorWeb.Admin.SettingsRefusal
  alias ConfluencePhxMirrorWeb.Time

  @refresh_ms 10_000
  @queue_limit 100
  @delivered_limit 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, socket |> assign(page_title: "Mail") |> load()}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    paused? = not Settings.mail_paused?()

    case Settings.update(%{"mail.paused" => paused?}, actor(socket)) do
      {:ok, _applied} ->
        {:noreply, socket |> load() |> put_flash(:info, paused_message(paused?))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, SettingsRefusal.message(reason))}
    end
  end

  def handle_event("purge", _params, socket) do
    {:ok, deleted} = Notifications.purge_queue(actor(socket))

    {:noreply, socket |> load() |> put_flash(:info, purged_message(deleted))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
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
      page_title="Mail"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:mail} />
      </:subnav>

      <.admin_header
        title="Mail"
        subtitle="What is waiting to leave the mirror, and whether it may."
      >
        <:actions>
          <button
            type="button"
            id="mail-pause"
            phx-click="pause"
            class={["btn btn-sm gap-1.5", if(@paused?, do: "btn-warning", else: "btn-outline")]}
          >
            <.icon name={if @paused?, do: "hero-play", else: "hero-pause"} class="size-4" />
            {if @paused?, do: "Resume mail", else: "Pause mail"}
          </button>
          <button
            type="button"
            id="mail-purge"
            phx-click="purge"
            disabled={@counts.queued == 0 and @counts.failed == 0}
            data-confirm="Drop every message that has not been delivered? What was already sent stays in the history."
            class="btn btn-ghost btn-sm gap-1.5 text-error"
          >
            <.icon name="hero-trash" class="size-4" /> Purge queue
          </button>
        </:actions>
      </.admin_header>

      <div
        :if={@paused?}
        id="mail-paused"
        class="mt-4 rounded-xl border border-warning/40 bg-warning/10 px-4 py-3 text-xs"
      >
        <span class="font-medium">Mail is paused.</span>
        Nothing leaves the mirror: notifications and digests wait in the queue below and go out
        after the resume, and a reader's test message is refused. Sign-in links are not queued and
        keep working.
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-3">
        <.count_card id="mail-count-waiting" label="Waiting" value={@counts.queued} />
        <.count_card id="mail-count-refused" label="Refused by the relay" value={@counts.failed} />
        <.count_card id="mail-count-delivered" label="Delivered, ever" value={@counts.delivered} />
      </div>

      <section id="mail-queue" class="mt-6">
        <h2 class="text-sm font-semibold">The queue</h2>
        <p class="mt-1 text-xs text-base-content/70">
          One row per message nobody has sent yet, oldest first. A refused row is one the relay
          turned down; it stays here so the reason is not lost.
        </p>

        <table :if={@queue != []} class="mt-3 w-full text-left text-xs">
          <thead class="border-b border-base-300/70 text-[11px] uppercase tracking-wider text-base-content/70">
            <tr>
              <th class="py-1.5 pr-3 font-medium">Queued</th>
              <th class="py-1.5 pr-3 font-medium">To</th>
              <th class="py-1.5 pr-3 font-medium">Subject</th>
              <th class="py-1.5 pr-3 font-medium">State</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/60">
            <tr :for={notification <- @queue} id={"mail-queued-#{notification.id}"}>
              <td class="py-2 pr-3 whitespace-nowrap text-base-content/70">
                {Time.ago(notification.inserted_at)}
              </td>
              <td class="py-2 pr-3">{notification.user && notification.user.email}</td>
              <td class="py-2 pr-3">{notification.subject}</td>
              <td class="py-2 pr-3">
                <span
                  :if={notification.error}
                  class="badge badge-error badge-sm"
                  title={notification.error}
                >
                  refused
                </span>
                <span :if={is_nil(notification.error)} class="badge badge-ghost badge-sm">
                  waiting
                </span>
              </td>
            </tr>
          </tbody>
        </table>

        <p :if={@queue == []} id="mail-queue-empty" class="mt-3 text-xs text-base-content/70">
          Nothing is waiting. Watchers' e-mail is written here when a page they watch changes.
        </p>

        <p :if={length(@queue) == @queue_limit} class="mt-2 text-[11px] text-base-content/70">
          The {@queue_limit} oldest are shown; purge or let the queue drain to see the rest.
        </p>
      </section>

      <section :if={@delivered != []} id="mail-delivered" class="mt-8">
        <h2 class="text-sm font-semibold">Delivered</h2>
        <p class="mt-1 text-xs text-base-content/70">
          The last {@delivered_limit}, newest first. A purge leaves these alone — they are the
          record of what was sent.
        </p>

        <ul class="mt-3 space-y-1 text-xs">
          <li :for={notification <- @delivered} class="flex flex-wrap items-baseline gap-x-2">
            <span class="text-base-content/70">{Time.ago(notification.delivered_at)}</span>
            <span class="font-medium">{notification.user && notification.user.email}</span>
            <span class="text-base-content/70">{notification.subject}</span>
          </li>
        </ul>
      </section>

      <p class="mt-8 text-[11px] text-base-content/70">
        The relay itself is configured on
        <.link navigate={~p"/admin/settings"} class="link">Settings → Mail server</.link>
        (see <code class="font-mono">docs/brevo-mail.md</code>), and Oban's raw rows for the
        <code class="font-mono">notifications</code>
        queue are on <.link navigate={~p"/admin/jobs"} class="link">Jobs</.link>.
      </p>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp count_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300/70 bg-base-100 px-4 py-3">
      <p class="text-[11px] uppercase tracking-wider text-base-content/70">{@label}</p>
      <p class="mt-1 text-xl font-semibold">{@value}</p>
    </div>
    """
  end

  defp load(socket) do
    assign(socket,
      paused?: Settings.mail_paused?(),
      counts: Notifications.counts(),
      queue: Notifications.queue(limit: @queue_limit),
      delivered: Notifications.delivered(@delivered_limit),
      queue_limit: @queue_limit,
      delivered_limit: @delivered_limit
    )
  end

  defp actor(socket), do: {:user, socket.assigns.current_user}

  defp paused_message(true),
    do: "Mail is paused. Notifications and digests wait in the queue; sign-in links keep working."

  defp paused_message(false), do: "Mail resumes: the queue below drains from the oldest message."

  defp purged_message(0), do: "The queue was already empty."

  defp purged_message(1), do: "One queued message was dropped."

  defp purged_message(count), do: "#{count} queued messages were dropped."
end
