defmodule ConfluencePhxMirrorWeb.Admin.GroupsLive do
  @moduledoc """
  The groups the sync has read, and what each one decides.

  A space permission or a page restriction names a group, and a group is a set of
  people: "who can read what" is only answerable with both halves in one place,
  and this screen is that place. The list says every group the mirror knows, how
  many members it holds, whether it decides anything, and when its membership
  was last read; one group says who is in it and which spaces and pages name it.

  Membership is mirrored, never invented — and Confluence Cloud answers only
  "which groups is this account in". The members of a group are therefore the
  people the mirror has read something about, not a site-wide directory, and the
  page says so where an auditor would otherwise trust it too much.

  **Sync with Confluence** re-reads the groups and the memberships without
  reading a single page: the same people run the identities screen queues.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirrorWeb.Admin.Paging
  alias ConfluencePhxMirrorWeb.Time

  # A group can be the whole staff, so both halves are bounded: the list pages in
  # the database, and a group's members are a window with its size beside them.
  @per_page 25
  @member_window 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Groups",
       group: nil,
       paused?: Settings.sync_paused?(),
       queued: nil,
       q: "",
       page: 1
     )}
  end

  @impl true
  def handle_params(%{"name" => name}, _uri, socket) do
    case Mirror.group(name) do
      nil ->
        # A group the last sync no longer lists is not an error page: the
        # directory is where the question continues.
        {:noreply, push_navigate(socket, to: ~p"/admin/groups")}

      group ->
        members = Mirror.group_members(group.name, limit: @member_window)

        {:noreply,
         assign(socket,
           page_title: group.name,
           group: group,
           members: members,
           members_window: @member_window,
           access: Mirror.group_access(group.name)
         )}
    end
  end

  def handle_params(params, _uri, socket) do
    q = Paging.query(params)
    page = Paging.page_number(params["page"])

    {:noreply,
     assign(socket,
       page_title: "Groups",
       group: nil,
       q: q,
       page: page,
       per_page: @per_page,
       total: Mirror.count_groups(query: q),
       groups:
         Mirror.group_catalogue(
           query: q,
           limit: @per_page,
           offset: Paging.offset(page, @per_page)
         )
     )}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/groups?#{[q: q, page: 1]}")}
  end

  @impl true
  def handle_event("sync_people", _params, socket) do
    case Sync.request_people("the groups screen, by #{socket.assigns.current_user.email}") do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:queued, %{job: job, what: "A read of the site's groups and memberships"})
         |> put_flash(:info, "Reading the site's groups and memberships.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue it: #{inspect(reason)}")}
    end
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
      page_title={@page_title}
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:groups} />
      </:subnav>

      <.admin_header
        :if={is_nil(@group)}
        title="Groups"
        subtitle="The Confluence groups the sync has read — and which of them decide who reads what."
      >
        <:actions>
          <.sync_people_button id="sync-groups" paused?={@paused?} />
        </:actions>
      </.admin_header>

      <.admin_header
        :if={@group}
        title={@group.name}
        subtitle={"#{@group.members} members, last read #{Time.ago(@group.read_at)}"}
      >
        <:actions>
          <.link navigate={~p"/admin/groups"} class="btn btn-ghost btn-sm">All groups</.link>
          <.sync_people_button id="sync-group" paused?={@paused?} />
        </:actions>
      </.admin_header>

      <.job_notice :if={@queued} job={@queued.job} what={@queued.what} id="groups-job-queued" />

      <p :if={@paused?} id="groups-paused" class="mt-3 max-w-3xl text-xs">
        Confluence calls are paused, so memberships cannot be re-read now — these are the groups and
        members the last run stored. <a href={~p"/admin/settings"} class="link">Resume in Settings</a>.
      </p>

      <%= if @group do %>
        <div class="mt-4 grid gap-4 lg:grid-cols-2">
          <section id="group-members" class="rounded-2xl border border-base-300/70 bg-base-100">
            <div class="flex items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3">
              <h2 class="text-sm font-semibold">Members</h2>
              <span class="badge badge-ghost badge-sm">{@group.members}</span>
            </div>

            <p
              :if={@members == []}
              id="group-members-empty"
              class="px-5 py-4 text-sm text-base-content/70"
            >
              The sync has read no member for this group. Confluence Cloud answers only
              "which groups is this account in", so a group whose members have not authored
              anything here stays empty until somebody runs a people sync over them.
            </p>

            <div :if={@members != []} class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>E-mail</th>
                    <th>Account</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={member <- @members} id={"member-#{member.subject_key}"}>
                    <td class="font-medium">
                      {member.display_name || member.email || member.account_id}
                    </td>
                    <td class="text-xs">{member.email}</td>
                    <td class="font-mono text-xs text-base-content/70">{member.account_id}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p
              :if={@group.members > length(@members)}
              class="border-t border-base-300/70 px-5 py-3 text-xs text-base-content/70"
            >
              Showing the first {length(@members)} of {@group.members}.
            </p>
          </section>

          <section id="group-access" class="rounded-2xl border border-base-300/70 bg-base-100">
            <div class="border-b border-base-300/70 px-5 py-3">
              <h2 class="text-sm font-semibold">What this group decides</h2>
            </div>

            <div class="px-5 py-4 text-sm">
              <p :if={@group.admin?} id="group-administers" class="mb-3 text-xs">
                The deployment names this group in <code class="font-mono">CM_ADMIN_GROUPS</code>,
                so its members administer this mirror.
              </p>

              <p
                :if={@access.spaces == [] and @access.pages == []}
                id="group-access-empty"
                class="text-base-content/70"
              >
                No space permission and no page restriction names it, so its membership decides
                nothing about reading here.
              </p>

              <div :if={@access.spaces != []} id="group-spaces">
                <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                  Spaces
                </h3>
                <ul class="mt-1 divide-y divide-base-300/60">
                  <li
                    :for={space <- @access.spaces}
                    class="flex items-center justify-between gap-3 py-1.5"
                  >
                    <.link
                      navigate={~p"/spaces/#{space.key}/overview"}
                      class="link font-mono text-xs"
                    >
                      {space.key}
                    </.link>
                    <span class="min-w-0 flex-1 truncate text-xs text-base-content/70">
                      {space.name}
                    </span>
                    <span class="badge badge-ghost badge-sm">{space.operation}</span>
                    <.access_source source={space.source} />
                  </li>
                </ul>
              </div>

              <div :if={@access.pages != []} id="group-pages" class="mt-4">
                <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                  Restricted pages
                </h3>
                <ul class="mt-1 divide-y divide-base-300/60">
                  <li
                    :for={page <- @access.pages}
                    class="flex items-center justify-between gap-3 py-1.5"
                  >
                    <.link
                      navigate={URLs.page_path(page.space, page.confluence_id, nil)}
                      class="min-w-0 flex-1 truncate text-xs link"
                    >
                      {page.title}
                    </.link>
                    <span class="badge badge-ghost badge-sm">{page.space}</span>
                    <.access_source source={page.source} />
                  </li>
                </ul>
              </div>
            </div>
          </section>
        </div>

        <p class="mt-4 max-w-3xl text-xs text-base-content/70">
          Confluence Cloud answers "which groups is this account in" one person at a time, so these
          members are the people the mirror has evidence of — the authors of pages and comments, and
          the accounts it holds. A member the mirror has read nothing about is not listed here.
        </p>
      <% else %>
        <section class="mt-4 overflow-hidden rounded-2xl border border-base-300/70 bg-base-100">
          <div class="flex items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3">
            <h2 class="text-sm font-semibold">Groups from Confluence</h2>
            <span class="badge badge-ghost badge-sm">{@total}</span>
          </div>

          <div class="border-b border-base-300/70 px-5 py-3">
            <.list_filter
              id="group-filter"
              query={@q}
              label="Filter groups by name"
              placeholder="Filter by name"
            />
          </div>

          <p
            :if={@groups == []}
            id="groups-empty"
            class="px-5 py-4 text-sm text-base-content/70"
          >
            No group the sync has read matches. Run a people sync to read the site's groups again.
          </p>

          <div :if={@groups != []} class="overflow-x-auto">
            <table id="groups" class="table table-sm">
              <thead>
                <tr>
                  <th>Group</th>
                  <th class="text-right">Members</th>
                  <th>Decides</th>
                  <th>Read</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={group <- @groups} id={"group-#{group.key}"}>
                  <td>
                    <.link navigate={~p"/admin/groups/#{group.name}"} class="link font-medium">
                      {group.name}
                    </.link>
                  </td>
                  <td class="text-right tabular-nums">{group.members}</td>
                  <td class="space-x-1">
                    <span :if={group.admin?} class="badge badge-primary badge-sm">
                      administers the mirror
                    </span>
                    <span :if={group.decides_access?} class="badge badge-ghost badge-sm">
                      decides who reads
                    </span>
                    <span
                      :if={not group.admin? and not group.decides_access?}
                      class="text-xs text-base-content/60"
                    >
                      nothing
                    </span>
                  </td>
                  <td class="text-xs text-base-content/70">
                    <.local_time at={group.read_at}>{Time.ago(group.read_at)}</.local_time>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <.list_pager
            :if={@total > @per_page}
            id="group-pager"
            path={~p"/admin/groups"}
            page={@page}
            total={@total}
            per_page={@per_page}
            params={%{q: @q}}
          />
        </section>

        <p class="mt-4 max-w-3xl text-xs text-base-content/70">
          A group decides who reads when a space permission or a page restriction names it: what its
          members can open is the sum of those. It administers the mirror when the deployment names
          it in <code class="font-mono">CM_ADMIN_GROUPS</code>. Membership is read one person at a
          time, from the people the mirror has evidence of — see
          <a href={~p"/admin/identities"} class="link">Identities</a>
          for that list.
        </p>
      <% end %>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :paused?, :boolean, required: true

  defp sync_people_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="sync_people"
      class="btn btn-outline btn-sm"
      disabled={@paused?}
      title={if @paused?, do: "Confluence calls are paused — resume in Settings"}
    >
      Sync with Confluence
    </button>
    """
  end

  # A grant the sync read is the site's; the other two are this mirror's own
  # decisions on top of it, and an audit has to see which is which.
  attr :source, :atom, required: true, values: [:site, :granted_here, :revoked_here]

  defp access_source(%{source: :site} = assigns) do
    ~H"""
    <span class="text-[11px] text-base-content/50">the site</span>
    """
  end

  defp access_source(%{source: :granted_here} = assigns) do
    ~H"""
    <span class="badge badge-info badge-sm">added here</span>
    """
  end

  defp access_source(%{source: :revoked_here} = assigns) do
    ~H"""
    <span class="badge badge-warning badge-sm">taken away here</span>
    """
  end
end
