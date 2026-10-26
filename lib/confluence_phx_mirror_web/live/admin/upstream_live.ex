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
  alias ConfluencePhxMirror.Sync.{ReconcileWorker, TrashAbsentWorker}
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
    case ReconcileWorker.new(%{"trigger" => "the admin screen, by #{who(socket)}"})
         |> Oban.insert() do
      {:ok, _job} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "A verify pass is queued. It counts and names ids — it does not read pages — " <>
             "so it finishes in seconds per space."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue the pass: #{inspect(reason)}")}
    end
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
        :if={@absent == 0}
        id="upstream-none"
        class="mt-6 rounded-xl border border-base-300/70 bg-base-100 p-4 text-sm text-base-content/70"
      >
        Every page the mirror holds is one Confluence still lists. Nothing to review;
        “Check the site again” asks the site without reading a single page.
      </p>

      <section :if={@spaces != []} class="mt-6">
        <h2 class="text-sm font-semibold">Spaces holding absent pages</h2>
        <p class="mt-0.5 text-xs text-base-content/70">
          The site did not name these pages the last time anyone checked. A lost permission looks
          exactly like a deletion from here, which is why nothing moves without you.
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

    assign(socket,
      spaces: spaces,
      pages: pages,
      spaces_list: Enum.map(spaces, & &1.space),
      absent: Mirror.count_absent(),
      more_pages?: length(all_pages) > @page_window,
      page_window: @page_window
    )
  end

  defp actor(socket), do: {:user, socket.assigns.current_user}

  defp who(socket) do
    case socket.assigns.current_user do
      %{email: email} -> email
      _no_user -> "an administrator"
    end
  end
end
