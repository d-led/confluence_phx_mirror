defmodule ConfluencePhxMirrorWeb.AdminComponents do
  @moduledoc """
  The admin area's chrome: one compact header and the section tabs, so the
  admin screens read as parts of one place instead of six.

  The split follows what each page is for: Overview and Webhooks are live,
  Sync log and Audit stream, Users are editable, and Settings is a static read
  of the configuration the mirror booted with.
  """

  use ConfluencePhxMirrorWeb, :html

  @tabs [
    {:overview, "Overview", "hero-squares-2x2"},
    {:jobs, "Jobs", "hero-queue-list"},
    {:sync_log, "Sync log", "hero-bars-arrow-down"},
    {:webhooks, "Webhooks", "hero-bolt"},
    {:audit, "Audit", "hero-clipboard-document-list"},
    {:trash, "Trash", "hero-trash"},
    {:upstream, "Missing pages", "hero-arrow-path"},
    {:users, "Users", "hero-users"},
    {:identities, "Identities", "hero-identification"},
    {:permissions, "Permissions", "hero-lock-closed"},
    {:settings, "Settings", "hero-cog-6-tooth"}
  ]

  @doc """
  The admin page header: title, one line of context, the page's actions and the
  tabs to the other admin sections.
  """
  attr :current, :atom, required: true, values: Enum.map(@tabs, &elem(&1, 0))
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def admin_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-xl font-semibold leading-tight">{@title}</h1>
        <p :if={@subtitle} class="mt-0.5 text-xs text-base-content/70">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>

    <nav
      class="mt-3 -mb-px flex gap-1 overflow-x-auto border-b border-base-300/70"
      aria-label="Administration"
    >
      <.link
        :for={{key, label, icon} <- tabs()}
        navigate={tab_path(key)}
        class={[
          "inline-flex shrink-0 items-center gap-1.5 border-b-2 px-2.5 py-2 text-xs font-medium transition",
          if(@current == key,
            do: "border-primary text-primary",
            else:
              "border-transparent text-base-content/70 hover:border-base-300 hover:text-base-content"
          )
        ]}
        aria-current={@current == key && "page"}
      >
        <.icon name={icon} class="size-3.5 shrink-0" /> {label}
      </.link>
    </nav>
    """
  end

  defp tabs, do: @tabs

  @doc """
  Who this mirror let in, and the dialog that lets one more — for a space or for a
  page.

  Confluence's own members screen asks one question ("who?") and answers with
  people and groups; this is the same shape on the mirror's own authority. It
  takes a `level` so the same component serves both, and never edits what the
  site decided: what it adds is marked, listed apart, and removable.
  """
  attr :level, :string, required: true, values: ~w(space page)
  attr :grants, :map, required: true
  attr :granting?, :boolean, default: false
  attr :query, :string, default: ""
  attr :people, :list, default: []
  attr :groups, :list, default: []

  def access_grants(assigns) do
    ~H"""
    <div class="mt-4 border-t border-primary/20 pt-3" id={"#{@level}-granted"}>
      <div class="flex items-center justify-between gap-2">
        <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
          Granted here
        </p>
        <button
          type="button"
          phx-click="grant_open"
          phx-value-level={@level}
          id={"#{@level}-open-grant"}
          class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
        >
          Add people or groups
        </button>
      </div>

      <p
        :if={@grants.granted == []}
        id={"#{@level}-granted-none"}
        class="mt-1 text-[11px] text-base-content/70"
      >
        Nothing granted here — access is Confluence's decision alone.
      </p>

      <ul :if={@grants.granted != []} class="mt-1 space-y-1 text-xs">
        <li
          :for={row <- @grants.granted}
          id={"#{@level}-granted-#{row.subject_type}-#{row.subject_key}"}
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
            phx-click="grant_revoke"
            phx-value-level={@level}
            phx-value-subject_type={row.subject_type}
            phx-value-subject_key={row.subject_key}
            id={"#{@level}-revoke-#{row.subject_type}-#{row.subject_key}"}
            class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
          >
            Remove
          </button>
        </li>
      </ul>

      <div :if={@grants.removed != []} id={"#{@level}-removed-here"} class="mt-3">
        <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
          Removed here
        </p>
        <p class="mt-0.5 text-[11px] text-base-content/70">
          Confluence still lists them; the mirror refuses them. Every sync leaves this in place.
        </p>

        <ul class="mt-1 space-y-1 text-xs">
          <li
            :for={row <- @grants.removed}
            id={"#{@level}-removed-#{row.subject_type}-#{row.subject_key}"}
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
              phx-click="restore_subject"
              phx-value-level={@level}
              phx-value-subject_type={row.subject_type}
              phx-value-subject_key={row.subject_key}
              id={"#{@level}-restore-#{row.subject_type}-#{row.subject_key}"}
              class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
            >
              Restore
            </button>
          </li>
        </ul>
      </div>

      <div
        :if={@granting?}
        id={"#{@level}-grant-dialog"}
        class="mt-3 rounded-lg border border-primary/30 bg-base-100 p-3"
      >
        <div class="flex items-start justify-between gap-2">
          <p class="text-xs font-semibold">Who else should read this?</p>
          <button
            type="button"
            phx-click="grant_close"
            id={"#{@level}-close-grant"}
            class="btn btn-ghost btn-xs"
          >
            Close
          </button>
        </div>

        <form id={"#{@level}-grant-search"} phx-change="grant_search" phx-submit="grant_search">
          <input
            type="search"
            name="term"
            value={@query}
            phx-debounce="200"
            placeholder="Search people and groups"
            aria-label="Search people and groups"
            class="input input-sm mt-2 min-h-11 w-full rounded-lg sm:min-h-0"
          />
        </form>

        <ul :if={@people != [] or @groups != []} class="mt-2 space-y-1 text-xs">
          <li
            :for={person <- @people}
            id={"#{@level}-grant-person-#{person.account_id}"}
            class="flex flex-wrap items-center justify-between gap-2"
          >
            <span class="flex min-w-0 flex-wrap items-baseline gap-2">
              <span class="badge badge-ghost badge-xs">person</span>
              <span class="truncate font-medium">{person.display_name || person.account_id}</span>
              <span class="font-mono text-[10px] text-base-content/50">{person.account_id}</span>
            </span>
            <button
              type="button"
              phx-click="grant_add"
              phx-value-level={@level}
              phx-value-subject_type="user"
              phx-value-subject_key={person.account_id}
              id={"#{@level}-grant-add-person-#{person.account_id}"}
              class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
            >
              Add
            </button>
          </li>

          <li
            :for={group <- @groups}
            id={"#{@level}-grant-group-#{group}"}
            class="flex flex-wrap items-center justify-between gap-2"
          >
            <span class="flex min-w-0 flex-wrap items-baseline gap-2">
              <span class="badge badge-ghost badge-xs">group</span>
              <span class="truncate font-medium">{group}</span>
            </span>
            <button
              type="button"
              phx-click="grant_add"
              phx-value-level={@level}
              phx-value-subject_type="group"
              phx-value-subject_key={group}
              id={"#{@level}-grant-add-group-#{group}"}
              class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
            >
              Add
            </button>
          </li>
        </ul>

        <p
          :if={@people == [] and @groups == []}
          id={"#{@level}-grant-no-matches"}
          class="mt-2 text-[11px] text-base-content/70"
        >
          Nobody the mirror knows matches. A grant can only name somebody the site has shown.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Who the site says may read this, with the control that takes one of them away
  here.

  Every allowed identity is one row with a *Remove* beside it, because the
  question an administrator arrives with is "why can this person read it" and the
  next one is "stop that". Removing never edits Confluence: it marks the site's
  row as the mirror's refusal (`Mirror.remove_space_reader/4`), which the next
  sync leaves alone and the *Removed here* list can undo.
  """
  attr :level, :string, required: true, values: ~w(space page)
  attr :grants, :map, required: true

  def access_subjects(assigns) do
    ~H"""
    <div :if={@grants.synced? or @grants.removed != []} class="mt-2 space-y-2 text-xs">
      <div
        :if={@grants.anonymous}
        id={"#{@level}-access-anonymous"}
        class="flex items-center gap-2"
      >
        <span class="badge badge-warning badge-sm">anonymous readers</span>
        <.remove_reader level={@level} type="anonymous" key="" label="anonymous readers" />
      </div>

      <div :if={@grants.groups != []}>
        <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
          Groups
        </p>
        <ul class="mt-1 flex flex-wrap items-center gap-1">
          <li
            :for={group <- @grants.groups}
            id={"#{@level}-access-group-#{group}"}
            class="inline-flex items-center gap-1"
          >
            <span class="badge badge-ghost badge-sm">{group}</span>
            <.remove_reader level={@level} type="group" key={group} label={group} />
          </li>
        </ul>
      </div>

      <div :if={@grants.users != []}>
        <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/60">
          People
        </p>
        <ul class="mt-1 space-y-1">
          <li
            :for={user <- @grants.users}
            id={"#{@level}-access-user-#{user.key}"}
            class="flex flex-wrap items-baseline gap-2"
          >
            <span class="font-medium">{user.label}</span>
            <span class="font-mono text-[10px] text-base-content/50">{user.key}</span>
            <span :if={not user.account?} class="text-[10px] text-base-content/50">
              no account here yet
            </span>
            <.remove_reader level={@level} type="user" key={user.key} label={user.label} />
          </li>
        </ul>
      </div>

      <p
        :if={not @grants.synced?}
        id={"#{@level}-access-nobody"}
        class="text-[11px] text-base-content/70"
      >
        Every identity the site lists here was removed on this mirror, so only an administrator can
        read it. Restoring one brings the site's reader back.
      </p>
    </div>
    """
  end

  defp remove_reader(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="remove_subject"
      phx-value-level={@level}
      phx-value-subject_type={@type}
      phx-value-subject_key={@key}
      id={"#{@level}-remove-#{@type}-#{@key}"}
      aria-label={"Stop #{@label} reading this"}
      class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
    >
      Remove
    </button>
    """
  end

  defp tab_path(:overview), do: ~p"/admin"
  defp tab_path(:jobs), do: ~p"/admin/jobs"
  defp tab_path(:sync_log), do: ~p"/admin/sync-log"
  defp tab_path(:webhooks), do: ~p"/admin/webhooks"
  defp tab_path(:audit), do: ~p"/admin/audit"
  defp tab_path(:trash), do: ~p"/admin/trash"
  defp tab_path(:upstream), do: ~p"/admin/upstream"
  defp tab_path(:users), do: ~p"/admin/users"
  defp tab_path(:identities), do: ~p"/admin/identities"
  defp tab_path(:permissions), do: ~p"/admin/permissions"
  defp tab_path(:settings), do: ~p"/admin/settings"
end
