defmodule ConfluencePhxMirrorWeb.Admin.PermissionsLive do
  @moduledoc """
  Who may read what, as the last sync read it.

  Confluence decides access and the mirror replays that decision, so this screen
  shows it and does not change it. The two answers an administrator is most
  likely to confuse are "nobody is listed" and "everybody can read it", so a
  space with no mirrored permissions says *open* in a word rather than drawing an
  empty list.

  Only the access of the spaces on screen is counted, in one statement for the
  page (`Mirror.space_access_by/1`), so a site with hundreds of spaces costs the
  same as a site with a dozen.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Mirror

  # The directory is searched, not browsed: a page of forty is enough to work
  # through, and the filter runs in the database.
  @page_window 40

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       q: "",
       space: nil,
       grants: nil,
       page_title: "Permissions"
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q, space: nil, grants: nil) |> load()}
  end

  def handle_event("inspect", %{"space_id" => space_id}, socket) do
    space = Mirror.get_space!(String.to_integer(space_id))

    {:noreply, assign(socket, space: space, grants: Mirror.space_grants(space.id))}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, space: nil, grants: nil)}
  end

  defp load(socket) do
    spaces = Mirror.list_spaces(limit: @page_window, query: socket.assigns.q)

    assign(socket,
      spaces: spaces,
      access: Mirror.space_access_by(Enum.map(spaces, & &1.id))
    )
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
      page_title="Permissions"
      sidebar?={false}
    >
      <.admin_header
        current={:permissions}
        title="Permissions"
        subtitle="Mirrored from Confluence by the last sync. The mirror replays these decisions; it does not make them."
      />

      <form
        id="space-filter"
        phx-change="filter"
        phx-submit="filter"
        class="mt-5 max-w-md"
      >
        <input
          type="search"
          name="q"
          value={@q}
          phx-debounce="200"
          placeholder="Filter spaces by name or key"
          aria-label="Filter spaces"
          class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
        />
      </form>

      <div
        :if={@space}
        id="space-access-panel"
        class="mt-4 rounded-xl border border-primary/30 bg-primary/5 p-4"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="text-xs font-semibold">
              {@space.name} <span class="font-mono text-base-content/60">{@space.key}</span>
            </p>
            <p class="mt-0.5 text-[11px] text-base-content/70">
              From the last sync. A page inside this space may still be narrowed by its own
              restrictions.
            </p>
          </div>
          <button type="button" phx-click="close" id="close-space-access" class="btn btn-ghost btn-xs">
            Close
          </button>
        </div>

        <p
          :if={not @grants.synced?}
          id="space-access-open"
          class="mt-2 text-[11px] text-base-content/70"
        >
          No permissions are mirrored for this space, so nothing narrows it: every reader of the
          mirror can open it.
        </p>

        <div :if={@grants.synced?} class="mt-2 space-y-2 text-xs">
          <div :if={@grants.anonymous} id="space-access-anonymous">
            <span class="badge badge-warning badge-sm">anonymous readers</span>
          </div>

          <div :if={@grants.groups != []}>
            <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
              Groups
            </p>
            <div class="mt-1 flex flex-wrap gap-1">
              <span
                :for={group <- @grants.groups}
                id={"space-access-group-#{group}"}
                class="badge badge-ghost badge-sm"
              >
                {group}
              </span>
            </div>
          </div>

          <div :if={@grants.users != []}>
            <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
              People
            </p>
            <ul class="mt-1 space-y-1">
              <li
                :for={user <- @grants.users}
                id={"space-access-user-#{user.key}"}
                class="flex flex-wrap items-baseline gap-2"
              >
                <span class="font-medium">{user.label}</span>
                <span class="font-mono text-[10px] text-base-content/50">{user.key}</span>
                <span :if={not user.account?} class="text-[10px] text-base-content/50">
                  no account here yet
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <p :if={@spaces == []} id="spaces-empty" class="mt-6 text-sm text-base-content/70">
        No space matches this filter.
      </p>

      <ul
        :if={@spaces != []}
        id="space-list"
        class="mt-4 divide-y divide-base-300/60 rounded-xl border border-base-300/70"
      >
        <li
          :for={space <- @spaces}
          id={"space-row-#{space.id}"}
          class="flex flex-wrap items-center justify-between gap-3 px-4 py-2.5"
        >
          <div class="min-w-0">
            <p class="truncate text-sm font-medium">{space.name}</p>
            <p class="font-mono text-[10px] text-base-content/50">{space.key}</p>
          </div>

          <div class="flex flex-wrap items-center gap-1.5">
            <%= case Map.get(@access, space.id) do %>
              <% nil -> %>
                <span class="badge badge-ghost badge-sm" id={"space-open-#{space.id}"}>open</span>
              <% access -> %>
                <span :if={access.anonymous} class="badge badge-warning badge-sm">anonymous</span>
                <span :if={access.groups > 0} class="badge badge-ghost badge-sm">
                  {access.groups} {if access.groups == 1, do: "group", else: "groups"}
                </span>
                <span :if={access.users > 0} class="badge badge-ghost badge-sm">
                  {access.users} {if access.users == 1, do: "person", else: "people"}
                </span>
            <% end %>

            <button
              type="button"
              phx-click="inspect"
              phx-value-space_id={space.id}
              id={"inspect-space-#{space.id}"}
              class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
            >
              Inspect
            </button>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
