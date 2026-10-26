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

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.{ReconcileRun, ReconcileWorker, TrashAbsentWorker}
  alias ConfluencePhxMirror.Trash

  # A mirror that lost a space can have thousands of absent pages; the page shows
  # the newest and each space's own button takes the rest.
  @page_window 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Not upstream") |> load()}
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
        {:noreply, put_flash(socket, :error, "#{key} has nothing absent.")}

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
               "Trashing #{absent} pages of #{space.key} in the background; watch it in Jobs."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not queue it: #{inspect(reason)}")}
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
      page_title="Not upstream"
      sidebar?={false}
    >
      <.admin_header
        current={:upstream}
        title="Not upstream"
        subtitle="Pages the mirror holds that Confluence did not name. They are still readable until you trash them."
      >
        <:actions>
          <button type="button" phx-click="check" id="check-upstream" class="btn btn-outline btn-sm">
            Check the site again
          </button>
        </:actions>
      </.admin_header>

      <p
        :if={@running}
        id="upstream-running"
        class="mt-6 rounded-xl border border-info/40 bg-info/10 p-4 text-sm text-base-content/80"
      >
        <span class="font-semibold">A check is running.</span>
        It has settled {@running.observed} spaces so far, and each one is written down as it
        goes — if the job is interrupted it continues from there rather than starting over. What
        it finds lands here when it finishes.
      </p>

      <p
        :if={@absent == 0 and is_nil(@last_check) and is_nil(@running)}
        id="upstream-unchecked"
        class="mt-6 rounded-xl border border-warning/40 bg-warning/10 p-4 text-sm text-base-content/80"
      >
        <span class="font-semibold">Nobody has checked this mirror against the site yet.</span>
        Nothing here knows which pages Confluence still lists — an untouched mirror and one the
        site agrees with look exactly the same from the inside. “Check the site again” counts and
        names ids for every space (two requests each), reads no page, and records what it found.
      </p>

      <div
        :if={@absent == 0 and not is_nil(@last_check)}
        id="upstream-none"
        class="mt-6 rounded-xl border border-base-300/70 bg-base-100 p-4 text-sm text-base-content/70"
      >
        <p>
          The last check, <.local_time at={@last_check.finished_at} />,
          compared {@last_check.spaces} spaces and found every page the site lists. {@last_check.listed} needed a listing; the rest were settled by their counts, for {@last_check.asked} questions in all.
        </p>
        <p class="mt-1 text-xs">
          That is a statement about that moment, not about now — a page deleted since then is
          still mirrored until the next pass says otherwise.
        </p>
      </div>

      <section :if={@spaces != []} class="mt-6">
        <h2 class="text-sm font-semibold">Spaces holding absent pages</h2>
        <p :if={@checked_at} class="mt-0.5 text-xs text-base-content/70">
          The site did not name these pages when this mirror last asked, at
          <.local_time at={@checked_at} />. A lost permission looks exactly like a deletion from
          here, which is why nothing moves without you.
        </p>
        <p :if={is_nil(@checked_at)} class="mt-0.5 text-xs text-base-content/70">
          The site did not name these pages, but no check has finished since they were marked — the
          pass that marked them did not complete. Check again before acting on it.
        </p>

        <div class="mt-2 overflow-x-auto rounded-xl border border-base-300/70">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Key</th>
                <th>Name</th>
                <th class="text-right">Absent</th>
                <th>First noticed</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @spaces} id={"space-#{entry.space.key}"}>
                <td class="font-mono text-xs">{entry.space.key}</td>
                <td class="max-w-64 truncate">{entry.space.name}</td>
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
                    Trash all {entry.pages}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@pages != []} class="mt-8">
        <h2 class="text-sm font-semibold">Pages not named by the site</h2>

        <div class="mt-2 overflow-x-auto rounded-xl border border-base-300/70">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Title</th>
                <th>Space</th>
                <th>Type</th>
                <th>Absent since</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{page, space} <- @pages} id={"absent-#{page.id}"}>
                <td class="max-w-96 truncate">{page.title}</td>
                <td class="font-mono text-xs">{space.key}</td>
                <td class="text-xs">{page.type}</td>
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
                    Trash
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@more_pages?} class="mt-2 text-xs text-base-content/70">
          Showing the newest {@page_window}; each space's own button takes the rest.
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

    assign(socket,
      spaces: spaces,
      pages: pages,
      spaces_list: Enum.map(spaces, & &1.space),
      absent: Mirror.count_absent(),
      # What the last finished pass found, or `nil` when nobody has asked yet —
      # the difference between "nothing is absent" and "we do not know".
      last_check: last_check,
      checked_at: last_check && last_check.finished_at,
      # A pass in flight, so the screen can say that rather than "nobody has
      # checked" while one is plainly running.
      running: ReconcileRun.progress(),
      more_pages?: length(all_pages) > @page_window,
      page_window: @page_window
    )
  end

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
          "A check is already queued or running, so this click was folded into it. " <>
            "Its result lands here when it finishes."
        )

      {:ok, _job} ->
        put_flash(
          socket,
          :info,
          "A verify pass is queued. It counts and names ids — it does not read pages — " <>
            "so it finishes in seconds per space."
        )

      {:error, reason} ->
        put_flash(socket, :error, "Could not queue the pass: #{inspect(reason)}")
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
