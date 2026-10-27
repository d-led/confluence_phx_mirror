defmodule ConfluencePhxMirrorWeb.AdminComponents do
  @moduledoc """
  The admin area's chrome: a grouped sidebar naming every admin page, and the
  page's own header — title, one line of context, its actions.

  The sidebar is rendered into `Layouts.app`'s `:subnav` slot, so the admin
  screens share one left column instead of repeating a tab strip in each
  template. The grouping follows what an operator is doing: watching the
  mirror, minding its content, deciding who may read it, and configuring it.
  """

  use ConfluencePhxMirrorWeb, :html

  alias ConfluencePhxMirrorWeb.Admin.Paging

  @sections [
    {"Monitoring",
     [
       {:overview, "Overview", "hero-squares-2x2"},
       {:jobs, "Jobs", "hero-queue-list"},
       {:sync_log, "Sync log", "hero-bars-arrow-down"}
     ]},
    {"Content",
     [
       {:spaces, "Spaces", "hero-rectangle-stack"},
       {:upstream, "Missing pages", "hero-arrow-path"},
       {:trash, "Trash", "hero-trash"},
       {:audit, "Audit log", "hero-clipboard-document-list"}
     ]},
    {"Access",
     [
       {:users, "Users", "hero-users"},
       {:identities, "Identities", "hero-identification"},
       {:permissions, "Permissions", "hero-lock-closed"}
     ]},
    {"Configuration",
     [
       {:webhooks, "Webhooks", "hero-bolt"},
       {:settings, "Settings", "hero-cog-6-tooth"}
     ]}
  ]

  @pages Enum.flat_map(@sections, fn {_title, pages} -> pages end)

  @doc """
  The admin sidebar: every page, grouped, with the current one marked.

  Narrow screens get a disclosure carrying the current page's name instead of
  a column, so eleven entries do not push the content off the screen.
  """
  attr :current, :atom, required: true, values: Enum.map(@pages, &elem(&1, 0))

  def admin_nav(assigns) do
    assigns = assign(assigns, :page, page!(assigns.current))

    ~H"""
    <details class="lg:hidden">
      <summary class="flex cursor-pointer items-center gap-2 rounded-lg border border-base-300/70 bg-base-100 px-3 py-2 text-sm font-medium">
        <.icon name={@page.icon} class="size-4 shrink-0 text-base-content/70" />
        {@page.label}
        <span class="ml-auto text-[11px] font-normal uppercase tracking-wider text-base-content/70">
          Administration
        </span>
      </summary>
      <div class="mt-2 rounded-xl border border-base-300/70 bg-base-100 p-3">
        <.nav_sections current={@current} />
      </div>
    </details>

    <nav aria-label="Administration" class="hidden lg:block">
      <.nav_sections current={@current} />
    </nav>
    """
  end

  @doc """
  The admin page header: title, one line of context and the page's own actions.
  The way to the other admin pages is the sidebar (`admin_nav/1`).
  """
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
    """
  end

  attr :current, :atom, required: true

  defp nav_sections(assigns) do
    ~H"""
    <div :for={{title, pages} <- sections()} class="mb-6 last:mb-0">
      <p class="mb-1.5 px-3 text-[13px] font-semibold text-base-content">{title}</p>
      <ul class="space-y-0.5">
        <li :for={{key, label, icon} <- pages}>
          <.link
            navigate={page_path(key)}
            aria-current={key == @current && "page"}
            class={[
              "relative flex items-center gap-2.5 rounded-lg py-1.5 pl-4 pr-3 text-[13px] transition",
              if(key == @current,
                do: "bg-primary/10 font-medium text-primary",
                else: "text-base-content/80 hover:bg-base-200/70 hover:text-base-content"
              )
            ]}
          >
            <span
              :if={key == @current}
              aria-hidden="true"
              class="absolute inset-y-1.5 left-0 w-[3px] rounded-full bg-primary"
            ></span>
            <.icon name={icon} class="size-4 shrink-0" />
            {label}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp sections, do: @sections

  defp page!(key) do
    {^key, label, icon} = Enum.find(@pages, fn {candidate, _label, _icon} -> candidate == key end)
    %{label: label, icon: icon}
  end

  @doc """
  A list's filter: one field, and the answer travels in the URL.

  A filter that lives in the address is a filter a colleague can be sent, and
  the back button returns to the question before it. `:event` is the LiveView's
  own event name, so a screen whose filter already has one keeps it.
  """
  attr :id, :string, required: true
  attr :query, :string, default: ""
  attr :label, :string, required: true, doc: "what the field filters, for a screen reader"
  attr :event, :string, default: "filter"
  attr :placeholder, :string, default: "Filter"

  def list_filter(assigns) do
    ~H"""
    <form id={@id} phx-change={@event} phx-submit={@event} class="mt-2">
      <label class="sr-only" for={"#{@id}-input"}>{@label}</label>
      <input
        type="search"
        id={"#{@id}-input"}
        name="q"
        value={@query}
        phx-debounce="200"
        placeholder={@placeholder}
        class="input input-sm w-full max-w-xs"
      />
    </form>
    """
  end

  @doc """
  "page 2 of 40 · 987 in total" with Previous and Next, in the URL.

  A list is never cut off: whatever a screen holds, the pager reaches the end of
  it, and the filter being typed travels with the page number — otherwise the
  second page would answer a different question than the first.
  """
  attr :id, :string, required: true
  attr :path, :string, required: true, doc: "the list's own address, without a query"
  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :per_page, :integer, required: true
  attr :params, :map, default: %{}, doc: "the list's other query parameters, kept across pages"

  def list_pager(assigns) do
    assigns = assign(assigns, :pages, Paging.page_count(assigns.total, assigns.per_page))

    ~H"""
    <div :if={@pages > 1} id={@id} class="mt-3 flex flex-wrap items-center justify-between gap-2">
      <span class="text-[11px] text-base-content/70">
        page {@page} of {@pages} · {@total} in total
      </span>
      <div class="flex gap-1.5">
        <.link
          :if={@page > 1}
          patch={Paging.href(@path, Map.put(@params, "page", @page - 1))}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Previous
        </.link>
        <.link
          :if={@page < @pages}
          patch={Paging.href(@path, Map.put(@params, "page", @page + 1))}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Next
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  The field a space key is typed into.

  It carries the suggestions' own event (`:change`) and one hook, because a
  picked key has to be *written* into the field: the browser keeps the value of
  the input it has focus in, so an answer from the server cannot patch it, and a
  click that changes nothing on screen reads as a click that did nothing.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :change, :string, required: true, doc: "the event asked for suggestions while typing"
  attr :class, :string, default: "input input-sm"

  def space_key_input(assigns) do
    ~H"""
    <input
      type="text"
      id={@id}
      name={@name}
      value={@value}
      phx-change={@change}
      phx-debounce="150"
      phx-hook=".SpaceKeyField"
      autocomplete="off"
      placeholder="LOAD01"
      class={@class}
    />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SpaceKeyField">
      export default {
        mounted() {
          this.handleEvent("space_key_value", ({ value }) => {
            this.el.value = value
            if (document.activeElement === this.el) {
              this.el.setSelectionRange(value.length, value.length)
            }
          })
        }
      }
    </script>
    """
  end

  @doc """
  Spaces worth naming, offered under the field they are typed into.

  A space key is four to ten letters nobody memorises, and the site already
  knows every one of them: typing `load` should offer `LOAD01`, not a validation
  error after the fact. The list comes from `SpaceDirectory`, so a screenful of
  keys costs no request of its own.

  Picking one sends `pick_space` with the key; what that means is the screen's
  decision — this page adds it, the settings screen puts it in the field.
  """
  attr :id, :string, required: true
  attr :suggestions, :list, default: []
  attr :label, :string, required: true, doc: "what the list is a list of, for a screen reader"

  def space_suggestions(assigns) do
    ~H"""
    <ul
      :if={@suggestions != []}
      id={@id}
      aria-label={@label}
      class="mt-1 divide-y divide-base-300/60 overflow-hidden rounded-lg border border-base-300/70 bg-base-100"
    >
      <li :for={space <- @suggestions}>
        <button
          type="button"
          phx-click="pick_space"
          phx-value-key={space.key}
          id={"#{@id}-#{space.key}"}
          class="flex w-full items-baseline justify-between gap-3 px-2.5 py-1.5 text-left text-xs transition hover:bg-base-200"
        >
          <span class="truncate">{space[:name] || space.key}</span>
          <span class="shrink-0 font-mono text-[11px] text-base-content/70">{space.key}</span>
        </button>
      </li>
    </ul>
    """
  end

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

  # One address per admin page. Kept beside the section list so a new entry
  # without a path fails to compile rather than rendering a dead link.
  defp page_path(:overview), do: ~p"/admin"
  defp page_path(:jobs), do: ~p"/admin/jobs"
  defp page_path(:sync_log), do: ~p"/admin/sync-log"
  defp page_path(:webhooks), do: ~p"/admin/webhooks"
  defp page_path(:audit), do: ~p"/admin/audit"
  defp page_path(:trash), do: ~p"/admin/trash"
  defp page_path(:spaces), do: ~p"/admin/spaces"
  defp page_path(:upstream), do: ~p"/admin/upstream"
  defp page_path(:users), do: ~p"/admin/users"
  defp page_path(:identities), do: ~p"/admin/identities"
  defp page_path(:permissions), do: ~p"/admin/permissions"
  defp page_path(:settings), do: ~p"/admin/settings"
end
