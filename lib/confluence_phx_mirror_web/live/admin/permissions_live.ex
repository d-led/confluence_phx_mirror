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
       restricted: [],
       page: nil,
       page_grants: nil,
       granting?: false,
       grant_query: "",
       grant_people: [],
       grant_groups: [],
       page_title: "Permissions"
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply,
     socket
     |> assign(q: q, space: nil, grants: nil, restricted: [], page: nil, page_grants: nil)
     |> load()}
  end

  def handle_event("inspect", %{"space_key" => key}, socket) do
    {:noreply, inspect_space(socket, Mirror.get_space_by_key(key))}
  end

  # A page's own restrictions are the half of the answer the space view cannot
  # give: the space decides, and then the page narrows it further.
  def handle_event("inspect_page", %{"page_id" => page_id}, socket) do
    page = Mirror.get_page_by_id!(String.to_integer(page_id))

    {:noreply, assign(socket, page: page, page_grants: Mirror.page_grants(page))}
  end

  def handle_event("open_grant", _params, socket) do
    {:noreply, socket |> assign(granting?: true, grant_query: "") |> search_grants()}
  end

  def handle_event("close_grant", _params, socket) do
    {:noreply,
     assign(socket, granting?: false, grant_query: "", grant_people: [], grant_groups: [])}
  end

  def handle_event("search_grant", %{"term" => term}, socket) do
    {:noreply, socket |> assign(grant_query: term) |> search_grants()}
  end

  # Confluence's own dialog asks one question — who? — and answers with people and
  # groups in one list. So does this one, from what the mirror has read.
  def handle_event("grant_access", %{"subject_type" => type, "subject_key" => key}, socket) do
    case Mirror.grant_space_access(socket.assigns.space, type, key, actor(socket)) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{key} may now read #{socket.assigns.space.key}.")
         |> assign(granting?: false, grant_query: "")
         |> inspect_space(socket.assigns.space)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, grant_refusal(reason, key))}
    end
  end

  def handle_event("revoke_access", %{"subject_type" => type, "subject_key" => key}, socket) do
    case Mirror.revoke_space_access(socket.assigns.space, type, key, actor(socket)) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{key} may no longer read #{socket.assigns.space.key}.")
         |> inspect_space(socket.assigns.space)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, grant_refusal(reason, key))}
    end
  end

  def handle_event("close_page", _params, socket) do
    {:noreply, assign(socket, page: nil, page_grants: nil)}
  end

  def handle_event("close", _params, socket) do
    {:noreply,
     assign(socket, space: nil, grants: nil, restricted: [], page: nil, page_grants: nil)}
  end

  defp inspect_space(socket, space) do
    assign(socket,
      space: space,
      grants: Mirror.space_grants(space),
      restricted: Mirror.restricted_pages(space.id),
      page: nil,
      page_grants: nil
    )
  end

  @grant_window 8

  defp search_grants(socket) do
    term = socket.assigns.grant_query
    granted = taken_keys(socket)

    people =
      [limit: @grant_window, query: term]
      |> Mirror.people()
      |> Enum.reject(&taken?(&1.account_id, granted))

    groups =
      Mirror.synced_group_names()
      |> Enum.filter(&matches?(&1, term))
      |> Enum.reject(&taken?(&1, granted))
      |> Enum.take(@grant_window)

    assign(socket, grant_people: people, grant_groups: groups)
  end

  # A key already allowed — by the site or by us — is not offered again: the
  # table holds one row per subject and the dialog should not invite a duplicate.
  defp taken_keys(socket) do
    space = socket.assigns.space

    (Mirror.space_permissions(space.id) ++ Mirror.space_grants_here(space))
    |> Enum.map(& &1.subject_key)
  end

  defp taken?(key, taken), do: key in taken

  defp matches?(_value, term) when term in [nil, ""], do: true

  defp matches?(value, term),
    do: value |> String.downcase() |> String.contains?(String.downcase(term))

  defp grant_refusal(:not_authorized, _key),
    do: "Only an administrator may change who reads a space."

  defp grant_refusal(:space_is_open, _key), do: "This space is open — there is nothing to widen."

  defp grant_refusal(:unknown_identity, key),
    do: "The mirror has not seen #{key} yet — run a sync."

  defp grant_refusal(:unknown_group, key), do: "The sync has not read a group called #{key}."
  defp grant_refusal(:not_granted, key), do: "#{key} is not granted here."
  defp grant_refusal(_reason, key), do: "Could not change access for #{key}."

  defp actor(%{assigns: %{current_user: user}}), do: {:user, user}

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
          :if={@grants.personal}
          id="space-access-personal"
          class="mt-2 text-[11px] text-base-content/70"
        >
          A personal space: only <span class="font-mono">{@grants.personal}</span> may read it, and
          an administrator. It needs no permission rows to be narrowed — being somebody's is
          enough.
        </p>

        <p
          :if={not @grants.synced? and is_nil(@grants.personal)}
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

        <div class="mt-4 border-t border-primary/20 pt-3" id="space-granted">
          <div class="flex items-center justify-between gap-2">
            <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
              Granted here
            </p>
            <button
              type="button"
              phx-click="open_grant"
              id="open-grant"
              class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
            >
              Add people or groups
            </button>
          </div>

          <p
            :if={@grants.granted == []}
            id="granted-none"
            class="mt-1 text-[11px] text-base-content/70"
          >
            Nothing granted here — who may read this space is Confluence's decision alone.
          </p>

          <ul :if={@grants.granted != []} class="mt-1 space-y-1 text-xs">
            <li
              :for={row <- @grants.granted}
              id={"granted-#{row.subject_type}-#{row.subject_key}"}
              class="flex flex-wrap items-center justify-between gap-2"
            >
              <span class="flex min-w-0 flex-wrap items-baseline gap-2">
                <span class="badge badge-outline badge-xs">{row.subject_type}</span>
                <span class="truncate font-medium">{Map.get(row, :label) || row.subject_key}</span>
                <span :if={Map.get(row, :label)} class="font-mono text-[10px] text-base-content/50">
                  {row.subject_key}
                </span>
              </span>
              <button
                type="button"
                phx-click="revoke_access"
                phx-value-subject_type={row.subject_type}
                phx-value-subject_key={row.subject_key}
                id={"revoke-#{row.subject_type}-#{row.subject_key}"}
                class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
              >
                Remove
              </button>
            </li>
          </ul>

          <div
            :if={@granting?}
            id="grant-dialog"
            class="mt-3 rounded-lg border border-primary/30 bg-base-100 p-3"
          >
            <div class="flex items-start justify-between gap-2">
              <p class="text-xs font-semibold">Who else should read this space?</p>
              <button
                type="button"
                phx-click="close_grant"
                id="close-grant"
                class="btn btn-ghost btn-xs"
              >
                Close
              </button>
            </div>

            <form id="grant-search-form" phx-change="search_grant" phx-submit="search_grant">
              <input
                type="search"
                name="term"
                value={@grant_query}
                phx-debounce="200"
                placeholder="Search people and groups"
                aria-label="Search people and groups"
                class="input input-sm mt-2 min-h-11 w-full rounded-lg sm:min-h-0"
              />
            </form>

            <ul
              :if={@grant_people != [] or @grant_groups != []}
              class="mt-2 space-y-1 text-xs"
            >
              <li
                :for={person <- @grant_people}
                id={"grant-person-#{person.account_id}"}
                class="flex flex-wrap items-center justify-between gap-2"
              >
                <span class="flex min-w-0 flex-wrap items-baseline gap-2">
                  <span class="badge badge-ghost badge-xs">person</span>
                  <span class="truncate font-medium">{person.display_name || person.account_id}</span>
                  <span class="font-mono text-[10px] text-base-content/50">{person.account_id}</span>
                </span>
                <button
                  type="button"
                  phx-click="grant_access"
                  phx-value-subject_type="user"
                  phx-value-subject_key={person.account_id}
                  id={"grant-add-person-#{person.account_id}"}
                  class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
                >
                  Add
                </button>
              </li>

              <li
                :for={group <- @grant_groups}
                id={"grant-group-#{group}"}
                class="flex flex-wrap items-center justify-between gap-2"
              >
                <span class="flex min-w-0 flex-wrap items-baseline gap-2">
                  <span class="badge badge-ghost badge-xs">group</span>
                  <span class="truncate font-medium">{group}</span>
                </span>
                <button
                  type="button"
                  phx-click="grant_access"
                  phx-value-subject_type="group"
                  phx-value-subject_key={group}
                  id={"grant-add-group-#{group}"}
                  class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
                >
                  Add
                </button>
              </li>
            </ul>

            <p
              :if={@grant_people == [] and @grant_groups == []}
              id="grant-no-matches"
              class="mt-2 text-[11px] text-base-content/70"
            >
              Nobody the mirror knows matches. A grant can only name somebody the site has shown.
            </p>
          </div>
        </div>

        <div
          :if={@restricted != []}
          id="restricted-pages"
          class="mt-4 border-t border-primary/20 pt-3"
        >
          <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
            Pages narrowed further
          </p>
          <ul class="mt-1 space-y-1 text-xs">
            <li
              :for={{page, subjects} <- @restricted}
              id={"restricted-page-#{page.id}"}
              class="flex flex-wrap items-center justify-between gap-2"
            >
              <span class="min-w-0 truncate">{page.title}</span>
              <span class="flex items-center gap-2">
                <span class="badge badge-ghost badge-sm">
                  {subjects} {if subjects == 1, do: "subject", else: "subjects"}
                </span>
                <button
                  type="button"
                  phx-click="inspect_page"
                  phx-value-page_id={page.id}
                  id={"inspect-page-#{page.id}"}
                  class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
                >
                  Inspect
                </button>
              </span>
            </li>
          </ul>
        </div>
      </div>

      <div
        :if={@page}
        id="page-access-panel"
        class="mt-3 rounded-xl border border-base-300 bg-base-200/40 p-4"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="text-xs font-semibold">{@page.title}</p>
            <p class="mt-0.5 text-[11px] text-base-content/70">
              A restricted page is readable only by the subjects listed here, whatever the space
              allows — the two are not added together.
            </p>
          </div>
          <button
            type="button"
            phx-click="close_page"
            id="close-page-access"
            class="btn btn-ghost btn-xs"
          >
            Close
          </button>
        </div>

        <div class="mt-2 space-y-2 text-xs">
          <div :if={@page_grants.anonymous} id="page-access-anonymous">
            <span class="badge badge-warning badge-sm">anonymous readers</span>
          </div>

          <div :if={@page_grants.groups != []}>
            <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
              Groups
            </p>
            <div class="mt-1 flex flex-wrap gap-1">
              <span
                :for={group <- @page_grants.groups}
                id={"page-access-group-#{group}"}
                class="badge badge-ghost badge-sm"
              >
                {group}
              </span>
            </div>
          </div>

          <div :if={@page_grants.users != []}>
            <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
              People
            </p>
            <ul class="mt-1 space-y-1">
              <li
                :for={user <- @page_grants.users}
                id={"page-access-user-#{user.key}"}
                class="flex flex-wrap items-baseline gap-2"
              >
                <span class="font-medium">{user.label}</span>
                <span class="font-mono text-[10px] text-base-content/50">{user.key}</span>
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
            <span
              :if={Mirror.personal_owner(space)}
              class="badge badge-outline badge-sm"
              id={"space-personal-#{space.id}"}
            >
              personal
            </span>

            <%= case Map.get(@access, space.id) do %>
              <% nil -> %>
                <span
                  :if={is_nil(Mirror.personal_owner(space))}
                  class="badge badge-ghost badge-sm"
                  id={"space-open-#{space.id}"}
                >
                  open
                </span>
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
              phx-value-space_key={space.key}
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
