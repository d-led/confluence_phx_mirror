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

    {:noreply,
     assign(socket, page: page, page_grants: Mirror.page_grants(page), dialog_level: nil)}
  end

  def handle_event("grant_open", %{"level" => level}, socket) do
    {:noreply, socket |> assign(dialog_level: level, grant_query: "") |> search_grants()}
  end

  def handle_event("grant_close", _params, socket) do
    {:noreply, clear_grant_dialog(socket)}
  end

  def handle_event("grant_search", %{"term" => term}, socket) do
    {:noreply, socket |> assign(grant_query: term) |> search_grants()}
  end

  # Confluence's own dialog asks one question — who? — and answers with people and
  # groups in one list. So does this one, from what the mirror has read.
  def handle_event("grant_add", params, socket) do
    %{"level" => level, "subject_type" => type, "subject_key" => key} = params

    case add_grant(socket, level, type, key) do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> clear_grant_dialog() |> refresh_panel()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, grant_refusal(reason, key))}
    end
  end

  def handle_event("grant_revoke", params, socket) do
    %{"level" => level, "subject_type" => type, "subject_key" => key} = params

    case remove_grant(socket, level, type, key) do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> refresh_panel()}

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
      page_grants: nil,
      dialog_level: nil
    )
  end

  @grant_window 8

  # The dialog searches what the mirror knows: people the content names, and the
  # groups the sync has read. A key that is already allowed — by the site or by us
  # — is not offered again, because the table holds one row per subject.
  defp search_grants(socket) do
    term = socket.assigns.grant_query
    taken = taken_keys(socket)

    people =
      [limit: @grant_window, query: term]
      |> Mirror.people()
      |> Enum.reject(&taken?(&1.account_id, taken))

    groups =
      Mirror.synced_group_names()
      |> Enum.filter(&matches?(&1, term))
      |> Enum.reject(&taken?(&1, taken))
      |> Enum.take(@grant_window)

    assign(socket, grant_people: people, grant_groups: groups)
  end

  defp taken_keys(%{assigns: %{dialog_level: "page", page: page}}) when not is_nil(page),
    do: page |> Mirror.page_grants() |> all_subject_keys()

  defp taken_keys(%{assigns: %{space: space}}) when not is_nil(space),
    do: space |> Mirror.space_grants() |> all_subject_keys()

  defp taken_keys(_socket), do: []

  # Everything a target already allows, whether the site said it or we did.
  defp all_subject_keys(grants) do
    groups = grants.groups ++ Enum.map(grants.granted, & &1.subject_key)
    users = Enum.map(grants.users, & &1.key) ++ Enum.map(grants.granted, & &1.subject_key)
    groups ++ users
  end

  defp taken?(key, taken), do: key in taken

  defp matches?(_value, term) when term in [nil, ""], do: true

  defp matches?(value, term),
    do: value |> String.downcase() |> String.contains?(String.downcase(term))

  defp add_grant(socket, "space", type, key) do
    case Mirror.grant_space_access(socket.assigns.space, type, key, actor(socket)) do
      {:ok, _row} -> {:ok, "#{key} may now read #{socket.assigns.space.key}."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_grant(socket, "page", type, key) do
    case Mirror.grant_page_access(socket.assigns.page, type, key, actor(socket)) do
      {:ok, _row} -> {:ok, "#{key} may now read “#{socket.assigns.page.title}”."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_grant(socket, "space", type, key) do
    case Mirror.revoke_space_access(socket.assigns.space, type, key, actor(socket)) do
      {:ok, _row} -> {:ok, "#{key} may no longer read #{socket.assigns.space.key}."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_grant(socket, "page", type, key) do
    case Mirror.revoke_page_access(socket.assigns.page, type, key, actor(socket)) do
      {:ok, _row} -> {:ok, "#{key} may no longer read “#{socket.assigns.page.title}”."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_grant_dialog(socket),
    do: assign(socket, dialog_level: nil, grant_query: "", grant_people: [], grant_groups: [])

  # Whichever panel is open, reload it: the counts and the lists answer the same
  # question the dialog just changed.
  defp refresh_panel(%{assigns: %{page: %{} = page}} = socket) do
    socket
    |> assign(page_grants: Mirror.page_grants(page))
    |> refresh_space()
  end

  defp refresh_panel(socket), do: refresh_space(socket)

  defp refresh_space(%{assigns: %{space: nil}} = socket), do: socket

  defp refresh_space(%{assigns: %{space: space}} = socket) do
    assign(socket,
      grants: Mirror.space_grants(space),
      restricted: Mirror.restricted_pages(space.id),
      access: socket.assigns.access
    )
  end

  # What the mirror refused, in the screen's own words. `%{key}` is the subject the
  # sentence is about; a sentence that names nobody ignores it.
  @refusals %{
    not_authorized: "Only an administrator may change who reads this.",
    space_is_open: "This space is open — there is nothing to widen.",
    page_is_open: "This page is unrestricted — there is nothing to widen.",
    unknown_identity: "The mirror has not seen %{key} yet — run a sync.",
    unknown_group: "The sync has not read a group called %{key}.",
    not_granted: "%{key} is not granted here."
  }

  defp grant_refusal(reason, key) do
    @refusals
    |> Map.get(reason, "Could not change access for %{key}.")
    |> String.replace("%{key}", key)
  end

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

        <.access_grants
          level="space"
          grants={@grants}
          granting?={@dialog_level == "space"}
          query={@grant_query}
          people={@grant_people}
          groups={@grant_groups}
        />

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

        <.access_grants
          level="page"
          grants={@page_grants}
          granting?={@dialog_level == "page"}
          query={@grant_query}
          people={@grant_people}
          groups={@grant_groups}
        />
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
