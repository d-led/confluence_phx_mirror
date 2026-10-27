defmodule ConfluencePhxMirrorWeb.Admin.TrashLive do
  @moduledoc """
  What a sync no longer finds in Confluence, waiting to be purged.

  Nothing here was lost by accident: a sync trashes what disappeared upstream and
  leaves the rows alone, so this is the deliberate step that removes them, their
  comments and their attachment files. Per-row buttons for one thing at a time;
  "Empty the trash" asks for a second click rather than a JavaScript dialog,
  because the second click is the confirmation.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Trash
  alias ConfluencePhxMirror.Trash.PurgeWorker

  # A site that lost a space can have thousands of pages in the trash; the page
  # shows the newest and "Empty the trash" takes them all.
  @page_window 200

  # The holding period the screen starts with. "Delete it later" needs a later,
  # and thirty days is long enough to notice a mistake and say so.
  @retention_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Trash") |> load()}
  end

  @impl true
  def handle_event("ask_to_empty", _params, socket) do
    {:noreply, assign(socket, confirming: true)}
  end

  def handle_event("cancel_empty", _params, socket) do
    {:noreply, assign(socket, confirming: false)}
  end

  def handle_event("retention_days", %{"days" => days}, socket) do
    {:noreply, change_retention(socket, days)}
  end

  def handle_event("ask_to_purge_due", _params, socket) do
    {:noreply, assign(socket, retention_confirming: true)}
  end

  def handle_event("cancel_purge_due", _params, socket) do
    {:noreply, assign(socket, retention_confirming: false)}
  end

  def handle_event("purge_due", _params, socket) do
    {:noreply, queue_retention_purge(socket)}
  end

  def handle_event("empty", _params, socket) do
    {:noreply, purge_everything(socket)}
  end

  def handle_event("purge_space", %{"key" => key}, socket) do
    {:noreply, purge_space(socket, key)}
  end

  def handle_event("purge_page", %{"id" => id}, socket) do
    {:noreply, purge_page(socket, id)}
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
      page_title="Trash"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:trash} />
      </:subnav>

      <.admin_header
        title="Trash"
        subtitle="Content a sync no longer finds in Confluence. Nothing here is readable."
      >
        <:actions>
          <%= if @confirming do %>
            <button type="button" phx-click="cancel_empty" class="btn btn-ghost btn-sm">
              Keep it
            </button>
            <button type="button" phx-click="empty" id="confirm-empty" class="btn btn-error btn-sm">
              Delete {@space_count} spaces and {@page_count} pages for good
            </button>
          <% else %>
            <button
              type="button"
              phx-click="ask_to_empty"
              id="empty-trash"
              class="btn btn-outline btn-sm"
              disabled={@empty?}
            >
              Empty the trash
            </button>
          <% end %>
        </:actions>
      </.admin_header>

      <p
        :if={@empty?}
        id="trash-empty"
        class="mt-6 rounded-xl border border-base-300/70 bg-base-100 p-4 text-sm text-base-content/70"
      >
        The trash is empty. A page, comment or space that disappears in Confluence
        is moved here by the next snapshot, never deleted on the spot.
      </p>

      <section :if={not @empty?} id="retention" class="mt-6 rounded-xl border border-base-300/70 p-4">
        <h2 class="text-sm font-semibold">Delete it later</h2>
        <p class="mt-0.5 text-xs text-base-content/70">
          A mirror that keeps everything it ever saw grows without bound. Set how long the trash
          holds something and it removes only what has been here that long — never anything younger,
          never anything still published.
        </p>

        <form
          id="retention-form"
          phx-change="retention_days"
          class="mt-3 flex flex-wrap items-center gap-2 text-sm"
        >
          <label for="retention-days" class="text-xs text-base-content/70">
            Held for at least
          </label>
          <input
            type="number"
            min="0"
            id="retention-days"
            name="days"
            value={@days}
            phx-debounce="300"
            class="input input-bordered input-sm w-20 tabular-nums"
          />
          <span class="text-xs text-base-content/70">days</span>
          <span id="retention-count" class="ml-2 text-xs text-base-content/70">
            {@due.spaces |> length()} spaces and {@due.pages |> length()} pages are older than that.
          </span>
        </form>

        <div class="mt-3 flex flex-wrap gap-2">
          <%= if @retention_confirming do %>
            <button type="button" phx-click="cancel_purge_due" class="btn btn-ghost btn-sm">
              Keep it
            </button>
            <button
              type="button"
              phx-click="purge_due"
              id="confirm-purge-due"
              class="btn btn-error btn-sm"
            >
              Delete {length(@due.spaces)} spaces and {length(@due.pages)} pages for good
            </button>
          <% else %>
            <button
              type="button"
              phx-click="ask_to_purge_due"
              id="purge-due"
              class="btn btn-outline btn-sm"
              disabled={@due.spaces == [] and @due.pages == []}
            >
              Delete what has been here {@days} days
            </button>
          <% end %>
        </div>
      </section>

      <section :if={@spaces != []} class="mt-6">
        <h2 class="text-sm font-semibold">Spaces</h2>
        <p class="mt-0.5 text-xs text-base-content/70">
          Deleted in Confluence. Purging removes the space, its pages, their comments and their attachment files.
        </p>

        <div class="mt-2 overflow-x-auto rounded-xl border border-base-300/70">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Key</th>
                <th>Name</th>
                <th class="text-right">Pages</th>
                <th>Trashed</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{space, pages} <- @spaces} id={"space-#{space.key}"}>
                <td class="font-mono text-xs">{space.key}</td>
                <td class="max-w-64 truncate">{space.name}</td>
                <td class="text-right tabular-nums">{pages}</td>
                <td class="text-xs text-base-content/70">
                  <.local_time at={space.deleted_at} />
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="purge_space"
                    phx-value-key={space.key}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete for good
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@pages != []} class="mt-8">
        <h2 class="text-sm font-semibold">Pages and blog posts</h2>
        <p class="mt-0.5 text-xs text-base-content/70">
          Deleted in Confluence outside a trashed space. Purging takes their comments and attachments with them.
        </p>

        <div class="mt-2 overflow-x-auto rounded-xl border border-base-300/70">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Title</th>
                <th>Space</th>
                <th>Type</th>
                <th>Trashed</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{page, space} <- @pages} id={"page-#{page.id}"}>
                <td class="max-w-96 truncate">{page.title}</td>
                <td class="font-mono text-xs">{space.key}</td>
                <td class="text-xs">{page.type}</td>
                <td class="text-xs text-base-content/70">
                  <.local_time at={page.deleted_at} />
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="purge_page"
                    phx-value-id={page.id}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete for good
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@more_pages?} class="mt-2 text-xs text-base-content/70">
          Showing the newest {@page_window}; “Empty the trash” takes the rest.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp load(socket) do
    spaces = Trash.spaces()
    all_pages = Trash.pages(limit: @page_window + 1)
    pages = Enum.take(all_pages, @page_window)
    # Whatever holding period the operator typed survives a reload of the lists.
    days = Map.get(socket.assigns, :days, @retention_days)

    assign(socket,
      spaces: spaces,
      pages: pages,
      spaces_list: Enum.map(spaces, &elem(&1, 0)),
      space_count: length(spaces),
      page_count: length(pages),
      more_pages?: length(all_pages) > @page_window,
      page_window: @page_window,
      confirming: false,
      retention_confirming: false,
      days: days,
      due: Trash.due(days),
      empty?: spaces == [] and pages == []
    )
  end

  # The purge walks every expired row and its attachment files, so it is a job
  # rather than work done in the click that asked for it.
  defp queue_retention_purge(socket) do
    %{days: days, due: due} = socket.assigns

    case %{"older_than_days" => days, "asked_by" => who(socket)}
         |> PurgeWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        socket
        |> put_flash(
          :info,
          "Deleting #{length(due.spaces)} spaces and #{length(due.pages)} pages in the " <>
            "background; watch it in Jobs."
        )
        |> assign(retention_confirming: false)

      {:error, reason} ->
        put_flash(socket, :error, "Could not queue it: #{inspect(reason)}")
    end
  end

  defp change_retention(socket, days) do
    case Integer.parse(String.trim(days)) do
      {value, ""} when value >= 0 -> assign(socket, days: value, due: Trash.due(value))
      _not_a_number -> socket
    end
  end

  defp purge_everything(socket) do
    spaces = length(socket.assigns.spaces)
    pages = length(socket.assigns.pages)

    Enum.each(socket.assigns.spaces, fn {space, _pages} ->
      Trash.purge_space(actor(socket), space)
    end)

    Enum.each(socket.assigns.pages, fn {page, _space} ->
      Trash.purge_page(actor(socket), page)
    end)

    socket
    |> put_flash(:info, "Purged #{spaces} spaces and #{pages} pages for good.")
    |> load()
  end

  defp purge_space(socket, key) do
    with {space, _pages} <-
           Enum.find(socket.assigns.spaces, fn {space, _} -> space.key == key end),
         {:ok, %{pages: pages}} <- Trash.purge_space(actor(socket), space) do
      socket
      |> put_flash(:info, "#{space.key} purged with #{pages} pages.")
      |> load()
    else
      nil -> put_flash(socket, :error, "#{key} is no longer in the trash.")
      {:error, :not_trashed} -> put_flash(socket, :error, "#{key} is live again.")
    end
  end

  defp purge_page(socket, id) do
    with {page, _space} <-
           Enum.find(socket.assigns.pages, fn {page, _} -> to_string(page.id) == id end),
         {:ok, :page} <- Trash.purge_page(actor(socket), page) do
      socket
      |> put_flash(:info, "“#{page.title}” purged.")
      |> load()
    else
      nil -> put_flash(socket, :error, "That page is no longer in the trash.")
      {:error, :not_trashed} -> put_flash(socket, :error, "That page is live again.")
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
