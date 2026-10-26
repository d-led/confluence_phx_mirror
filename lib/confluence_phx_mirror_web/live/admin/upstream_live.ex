defmodule ConfluencePhxMirrorWeb.Admin.UpstreamLive do
  @moduledoc """
  Pages the mirror holds that Confluence did not name — the review before the trash.

  A sync that lists a whole space already trashes what the site no longer returns.
  This screen answers the other question, which a sync cannot: *what do we hold
  that the site never mentions at all?* A verify pass answers it by counting and
  naming ids (see `ConfluencePhxMirror.Sync.Reconcile`), so a whole site costs a
  couple of requests per space and no page reads.

  Nothing here is automatic. A listing can leave a page out because the token
  lost a permission, because a space was reorganised, or because somebody deleted
  it — so the operator reads the list and decides. Trashing a page here moves it
  to `/admin/trash`, where the retention policy eventually removes it for good.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.{Jobs, Mirror}
  alias ConfluencePhxMirror.Sync.{ReconcileRun, ReconcileWorker, TrashAbsentWorker}
  alias ConfluencePhxMirror.Trash

  # A mirror that lost a space can have thousands of absent pages; the page shows
  # the newest and each space's own button takes the rest.
  @page_window 200

  # A pass settles a space every few seconds and a site can have a thousand of
  # them. Showing the first fact at once and folding the rest into one redraw a
  # second is faster than a person reads and cheaper than a query per space.
  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, ReconcileRun.topic())
    end

    {:ok,
     assign(socket, page_title: "Missing pages", refresh_timer: nil, refresh_pending?: false)
     |> load()}
  end

  # A pass writes its facts one space at a time; the screen follows them instead
  # of asking the operator to reload and hope.
  @impl true
  def handle_info({:reconcile_observed, _run_id}, %{assigns: %{refresh_timer: nil}} = socket),
    do: {:noreply, refresh_now(socket)}

  def handle_info({:reconcile_observed, _run_id}, socket),
    do: {:noreply, assign(socket, :refresh_pending?, true)}

  def handle_info({:reconcile_finished, _run_id}, socket),
    do: {:noreply, refresh_now(socket)}

  def handle_info(:refresh_cooldown, socket) do
    socket = assign(socket, refresh_timer: nil)

    if socket.assigns.refresh_pending? do
      {:noreply, socket |> assign(:refresh_pending?, false) |> refresh_now()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("check", _params, socket) do
    {:noreply, queue_check(socket)}
  end

  def handle_event("trash_page", %{"id" => id}, socket) do
    with {page, space} <-
           Enum.find(socket.assigns.pages, fn {page, _} -> to_string(page.id) == id end),
         {:ok, _trashed} <- Trash.trash_page(actor(socket), page, space) do
      {:noreply, socket |> put_flash(:info, "“#{page.title}” moved to the trash.") |> load()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "That page is no longer absent.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That page is no longer here.")}
    end
  end

  def handle_event("trash_space", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.spaces, fn %{space: space} -> space.key == key end) do
      nil ->
        {:noreply, put_flash(socket, :error, "#{key} has nothing to move.")}

      %{space: space, pages: absent} ->
        # A space can hold thousands of absent pages; the job takes them so the
        # click does not have to. `TrashAbsentWorker` is what moves them.
        args = %{"space_key" => space.key, "asked_by" => who(socket)}

        case args |> TrashAbsentWorker.new() |> Oban.insert() do
          {:ok, _job} ->
            {:noreply,
             put_flash(
               socket,
               :info,
               "Moving #{plural(absent, "page")} of #{space.key} to the trash. This runs in the background."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not start it: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      live={@socket}
      spaces={@spaces_list}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      mirror_host={@mirror_host}
      mirror_source={@mirror_source}
      page_title="Pages Confluence doesn't have"
      sidebar?={false}
    >
      <.admin_header
        current={:upstream}
        title="Pages Confluence doesn't have"
        subtitle="We still show them. Confluence doesn't."
      >
        <:actions>
          <button type="button" phx-click="check" id="check-upstream" class="btn btn-outline btn-sm">
            Check Confluence
          </button>
        </:actions>
      </.admin_header>

      <p
        :if={@in_flight}
        id="upstream-in-flight"
        class="mt-6 rounded-xl border border-info/40 bg-info/10 p-4 text-sm text-base-content/80"
      >
        <span class="font-semibold">Checking Confluence now.</span>
        <%= if @progress && @progress.settled > 0 do %>
          {@progress.settled} of {@spaces_count} spaces done — new findings appear below.<%= if @progress.failed > 0 do %>
            {@progress.failed} spaces could not be read.
          <% end %>
        <% else %>
          Starting. It only asks Confluence what it has — nothing is copied.
        <% end %>
      </p>

      <p
        :if={not @in_flight and not is_nil(@unfinished)}
        id="upstream-interrupted"
        class="mt-6 rounded-xl border border-warning/40 bg-warning/10 p-4 text-sm text-base-content/80"
      >
        <span class="font-semibold">The last check stopped early.</span>
        <%= if @progress && @progress.settled > 0 do %>
          It got through {@progress.settled} of {@spaces_count} spaces. Whatever it already found is
          below, and the next check carries on from there.
        <% else %>
          It stopped before finishing any space, so the next check starts over. Nothing below is
          new since then.
        <% end %>
      </p>

      <p
        :if={@absent == 0 and is_nil(@last_check) and not @in_flight and is_nil(@unfinished)}
        id="upstream-unchecked"
        class="mt-6 rounded-xl border border-warning/40 bg-warning/10 p-4 text-sm text-base-content/80"
      >
        <span class="font-semibold">Nobody has checked this against Confluence yet.</span>
        Until someone does, nobody knows which pages Confluence still has. Press “Check Confluence”
        — it only reads, and takes a while on a big site.
      </p>

      <div
        :if={@absent == 0 and not is_nil(@last_check) and not @in_flight}
        id="upstream-none"
        class="mt-6 rounded-xl border border-base-300/70 bg-base-100 p-4 text-sm text-base-content/70"
      >
        <p>
          <span class="font-semibold">Nothing is missing.</span>
          Last checked
          <.local_time at={@last_check.finished_at} />: {checked_sentence(@last_check, @summary)}
        </p>
        <p
          :if={@summary.counted == 0 and @summary.settled > 0}
          id="upstream-no-counts"
          class="mt-1 text-xs"
        >
          Confluence won't say how many pages a space has, so every space is compared page by page.
          That's why a check takes a while.
        </p>
        <p class="mt-1 text-xs">
          True as of that date, not for ever. A page deleted upstream appears here at the next check.
        </p>
      </div>

      <section :if={@spaces != []} class="mt-6">
        <h2 class="text-sm font-semibold">
          <span id="absent-total">{plural(@absent, "page")} in {plural(length(@spaces), "space")}</span>
          not in Confluence any more
        </h2>
        <p :if={@checked_at} class="mt-0.5 text-xs text-base-content/70">
          Confluence stopped listing them at the last check, <.local_time at={@checked_at} />.
          Missing can also mean Confluence hid the page from us, so nothing moves without you.
        </p>
        <p :if={is_nil(@checked_at)} class="mt-0.5 text-xs text-base-content/70">
          No finished check has confirmed this yet. Check again before acting on it.
        </p>
        <p class="mt-0.5 text-xs text-base-content/70">
          Moving them to the trash hides them here. Deleting for good happens later, on the Trash
          page.
        </p>

        <div class="mt-2 overflow-x-auto rounded-xl border border-base-300/70">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Space</th>
                <th class="text-right">Pages</th>
                <th>Missing since</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @spaces} id={"space-#{entry.space.key}"}>
                <td class="max-w-72 truncate">
                  <span class="font-mono text-xs">{entry.space.key}</span>
                  <span class="ml-1 text-base-content/70">{entry.space.name}</span>
                </td>
                <td class="text-right tabular-nums">{entry.pages}</td>
                <td class="text-xs text-base-content/70">
                  <.local_time at={entry.since} />
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="trash_space"
                    phx-value-key={entry.space.key}
                    class="btn btn-ghost btn-xs"
                  >
                    Move all {entry.pages} to trash
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@pages != []} class="mt-8">
        <h2 class="text-sm font-semibold">The same pages, one by one</h2>

        <div class="mt-2 overflow-x-auto rounded-xl border border-base-300/70">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Page</th>
                <th>Space</th>
                <th>Missing since</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{page, space} <- @pages} id={"absent-#{page.id}"}>
                <td class="max-w-96 truncate">{page.title}</td>
                <td class="font-mono text-xs">{space.key}</td>
                <td class="text-xs text-base-content/70">
                  <.local_time at={page.absent_since} />
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="trash_page"
                    phx-value-id={page.id}
                    id={"trash-#{page.id}"}
                    class="btn btn-ghost btn-xs"
                  >
                    Move to trash
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@more_pages?} class="mt-2 text-xs text-base-content/70">
          The newest {@page_window} are listed. The button by each space clears all of them.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp load(socket) do
    spaces = Mirror.absent_spaces()
    all_pages = Mirror.absent_pages(limit: @page_window + 1)
    pages = Enum.take(all_pages, @page_window)
    last_check = ReconcileRun.last_finished()
    unfinished = ReconcileRun.unfinished()

    assign(socket,
      spaces: spaces,
      pages: pages,
      spaces_list: Enum.map(spaces, & &1.space),
      absent: Mirror.count_absent(),
      # What the last finished pass found, or `nil` when nobody has asked yet —
      # the difference between "nothing is missing" and "we do not know".
      last_check: last_check,
      checked_at: last_check && last_check.finished_at,
      # Two different questions, from two different places. `in_flight` asks Oban
      # whether the job is still held; `unfinished` is the pass's own cursor. A
      # killed job leaves the second without the first, and the screen must say
      # that rather than call a dead pass "running".
      in_flight: Jobs.unfinished?(ReconcileWorker),
      unfinished: unfinished,
      # How far the pass being watched has got, and how much there is to get
      # through — the two numbers the status sentence needs.
      progress: unfinished && ReconcileRun.summary(unfinished.run),
      spaces_count: Mirror.count_spaces(),
      # What the last finished pass compared, so "nothing is missing" comes with
      # the numbers behind it.
      summary: last_check && ReconcileRun.summary(last_check),
      more_pages?: length(all_pages) > @page_window,
      page_window: @page_window
    )
  end

  # The first fact after a quiet spell is shown at once; the ones that follow
  # within the window are folded into the next redraw.
  defp refresh_now(socket) do
    socket
    |> cancel_refresh()
    |> assign(:refresh_pending?, false)
    |> load()
    |> assign(:refresh_timer, Process.send_after(self(), :refresh_cooldown, @refresh_ms))
  end

  defp cancel_refresh(%{assigns: %{refresh_timer: nil}} = socket), do: socket

  defp cancel_refresh(%{assigns: %{refresh_timer: timer}} = socket) do
    Process.cancel_timer(timer)
    assign(socket, :refresh_timer, nil)
  end

  # One sentence about what the last check compared, so the numbers cannot be read
  # apart from what they are counting.
  defp checked_sentence(last_check, summary) do
    looked_at = "#{number(last_check.spaces)} spaces"

    if summary.named > 0 do
      "#{looked_at} and #{number(summary.named)} pages, all found."
    else
      "#{looked_at}, all found."
    end
  end

  # 124149 is a number nobody reads; 124,149 is one they do.
  defp number(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  # One pass at a time (see `ReconcileWorker`'s uniqueness). Oban reports the
  # avoided duplicate as `conflict?: true` rather than an error, so a second
  # click while one is queued or running says so instead of saying nothing.
  defp queue_check(socket) do
    case ReconcileWorker.new(%{"trigger" => "the admin screen, by #{who(socket)}"})
         |> Oban.insert() do
      {:ok, %{conflict?: true}} ->
        put_flash(
          socket,
          :info,
          "A check is already queued or running. This click joined it."
        )

      {:ok, _job} ->
        put_flash(
          socket,
          :info,
          "Checking. It only asks Confluence what it has, and the result appears here."
        )

      {:error, reason} ->
        put_flash(socket, :error, "Could not start the check: #{inspect(reason)}")
    end
  end

  defp actor(socket), do: {:user, socket.assigns.current_user}

  defp who(socket) do
    case socket.assigns.current_user do
      %{email: email} -> email
      _no_user -> "an administrator"
    end
  end
end
