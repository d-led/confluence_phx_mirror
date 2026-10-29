defmodule ConfluencePhxMirrorWeb.Admin.UsersLive do
  @moduledoc """
  Reader accounts: who exists, how each one administers, which identities and
  groups it holds, and which tokens it has.

  Tokens are listed here and can be revoked — revoking only takes access away —
  but never minted: a token acts as its owner, so it is created by the reader on
  their own account page.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Admins, User}
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirrorWeb.Admin.Paging
  alias ConfluencePhxMirrorWeb.Time

  @impl true
  def mount(_params, _session, socket) do
    # A run changes accounts (a site switch-off, a person the site newly names),
    # and each change is audited; following the trail is what makes the list
    # behind this screen current instead of a snapshot of the last render.
    if connected?(socket), do: Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, Audit.topic())

    {:ok,
     assign(socket,
       new_token: nil,
       q: "",
       proxy_auth?: Application.get_env(:confluence_phx_mirror, :proxy_auth, false),
       proxy_header:
         Application.get_env(:confluence_phx_mirror, :proxy_auth_header, "x-forwarded-email"),
       allow_site_disabled?:
         Application.get_env(:confluence_phx_mirror, :allow_site_disabled_readers, false),
       paused?: Settings.sync_paused?(),
       queued: nil,
       page_title: "Users & tokens"
     )
     |> load()}
  end

  # Every event is a name and a handler: the clauses are one line each, so this
  # function reads as the table of what the page can be asked to do.
  @impl true
  def handle_event("filter", params, socket), do: filter(params, socket)
  def handle_event("set_disabled", params, socket), do: set_disabled(params, socket)
  def handle_event("change_role", params, socket), do: change_role(params, socket)
  def handle_event("add_group", params, socket), do: add_group(params, socket)
  def handle_event("remove_group", params, socket), do: remove_group(params, socket)
  def handle_event("unban", params, socket), do: unban(params, socket)
  def handle_event("ban", params, socket), do: ban(params, socket)
  def handle_event("delete_user", params, socket), do: delete_user(params, socket)

  def handle_event("create_service_token", params, socket),
    do: create_service_token(params, socket)

  def handle_event("revoke_service_token", params, socket),
    do: revoke_service_token(params, socket)

  def handle_event("revoke_token", params, socket), do: revoke_token(params, socket)
  def handle_event("dismiss_token", params, socket), do: dismiss_token(params, socket)

  # This screen's own sync: which group each identity is in, and whether the
  # site still has the account at all — no page is listed and no body is read.
  # Queued, not awaited: the answer is a handful of requests away, and the list
  # follows when the run writes what it found.
  def handle_event("sync_people", _params, socket) do
    case Sync.request_people("the users screen, by #{socket.assigns.current_user.email}") do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:queued, %{job: job, what: "A read of the site's groups and account status"})
         |> put_flash(:info, "Reading the site's groups and each account's status.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue it: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:audit_event, %{entity_type: "user"}}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp filter(%{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: q, users_page: 1) |> load()}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(users_page: Paging.page_number(params["u_page"]))
     |> load()}
  end

  # Disabling here is the mirror's own decision and stays independent of what
  # Confluence says; access is refused while either flag is set.
  defp set_disabled(%{"user_id" => user_id, "disabled" => value}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))
    disabled? = value == "true"

    case Accounts.set_disabled(user, disabled?, actor(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{user.email} is now #{if disabled?, do: "disabled", else: "enabled"}."
         )
         |> load()}

      {:error, :protected_admin} ->
        {:noreply,
         put_flash(socket, :error, "A seeded or bootstrap administrator cannot be disabled.")}

      {:error, :last_admin} ->
        {:noreply, put_flash(socket, :error, last_admin_message(user))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not change the account.")}
    end
  end

  defp change_role(%{"user_id" => user_id, "role" => role}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))

    case Accounts.change_role(user, role, actor(socket)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Role updated.") |> load()}

      {:error, :protected_admin} ->
        {:noreply, put_flash(socket, :error, "A seeded or bootstrap administrator stays one.")}

      {:error, :last_admin} ->
        {:noreply, put_flash(socket, :error, last_admin_message(user))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update the role.")}
    end
  end

  defp add_group(%{"user_id" => user_id, "group" => group}, socket) do
    grant(socket, user_id, group, fn granted ->
      if granted == "", do: "Choose a group first.", else: "#{granted} is granted here."
    end)
  end

  defp remove_group(%{"user_id" => user_id, "group" => group}, socket) do
    grant(socket, user_id, group, fn removed ->
      if removed == "",
        do: "That group was not granted here.",
        else: "#{removed} is no longer granted here."
    end)
  end

  # One group at a time, added or taken away, so the screen says which name it
  # changed — the old comma list made "saved" the only feedback, and a typo
  # looked exactly like a grant.
  defp grant(socket, user_id, group, message) do
    with_user(socket, user_id, fn user ->
      granted = user.groups || []
      normalised = group |> to_string() |> String.trim() |> String.downcase()
      next = if normalised in granted, do: granted -- [normalised], else: [normalised | granted]

      case Accounts.update_groups(user, next, actor(socket)) do
        {:ok, _} -> socket |> put_flash(:info, message.(normalised)) |> load()
        {:error, _} -> put_flash(socket, :error, "Could not change the groups.")
      end
    end)
  end

  # Linking identities is the identities page's business: this screen shows
  # what an account holds and says where to change it.

  defp unban(%{"user_id" => user_id}, socket) do
    with_user(socket, user_id, fn user ->
      case Accounts.unban(user, actor(socket)) do
        {:ok, _} ->
          socket
          |> put_flash(:info, "#{user.email} is unbanned. The other flags decide again.")
          |> load()

        {:error, _} ->
          put_flash(socket, :error, "Could not lift the ban.")
      end
    end)
  end

  defp ban(%{"user_id" => user_id}, socket) do
    with_user(socket, user_id, fn user ->
      case Accounts.ban(user, actor(socket)) do
        {:ok, _} ->
          socket
          |> put_flash(
            :info,
            "#{user.email} is banned: no access, and not deletable until unbanned."
          )
          |> load()

        {:error, :protected_admin} ->
          put_flash(socket, :error, "A seeded or bootstrap administrator cannot be banned.")

        {:error, :last_admin} ->
          put_flash(socket, :error, last_admin_message(user))

        {:error, _} ->
          put_flash(socket, :error, "Could not ban the account.")
      end
    end)
  end

  defp delete_user(%{"user_id" => user_id}, socket) do
    with_user(socket, user_id, fn user ->
      case Accounts.delete_user(user, actor(socket)) do
        {:ok, _} ->
          socket
          |> put_flash(:info, "#{user.email} is deleted, with its tokens and subscriptions.")
          |> load()

        {:error, :protected_admin} ->
          put_flash(socket, :error, "#{user.email} is a seeded or bootstrap administrator.")

        {:error, :banned} ->
          put_flash(socket, :error, "A banned account cannot be deleted — lift the ban first.")

        {:error, :last_admin} ->
          put_flash(socket, :error, last_admin_message(user))

        {:error, _} ->
          put_flash(socket, :error, "Could not delete the account.")
      end
    end)
  end

  defp create_service_token(%{"name" => name, "scope" => scope}, socket) do
    case Accounts.create_service_token(String.trim(name), scope, actor(socket)) do
      {:ok, plain, token} ->
        {:noreply,
         socket
         |> assign(new_token: %{user: "service: #{token.name}", token: plain})
         |> put_flash(:info, "Service token created — copy it now, it is shown once.")
         |> load()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create the token.")}
    end
  end

  defp revoke_service_token(%{"token_id" => token_id}, socket) do
    case Accounts.revoke_service_token(String.to_integer(token_id), actor(socket)) do
      :ok -> {:noreply, socket |> put_flash(:info, "Service token revoked.") |> load()}
      _ -> {:noreply, put_flash(socket, :error, "Service token not found.")}
    end
  end

  defp revoke_token(%{"user_id" => user_id, "token_id" => token_id}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))

    case Accounts.revoke_api_token(user, String.to_integer(token_id), actor(socket)) do
      :ok -> {:noreply, socket |> put_flash(:info, "Token revoked.") |> load()}
      _ -> {:noreply, put_flash(socket, :error, "Token not found.")}
    end
  end

  defp dismiss_token(_params, socket) do
    {:noreply, assign(socket, new_token: nil)}
  end

  defp actor(%{assigns: %{current_user: user}}), do: {:user, user}

  defp last_admin_message(user) do
    "#{user.email} is the mirror's last administrator — it has to keep one."
  end

  # An account the page no longer has (deleted in another tab, or by another
  # administrator) is not a crash.
  defp with_user(socket, user_id, fun) do
    case Accounts.get_user(String.to_integer(user_id)) do
      nil -> {:noreply, put_flash(socket, :error, "That account is gone already.")}
      user -> {:noreply, fun.(user)}
    end
  end

  defp load(socket) do
    users_page = socket.assigns[:users_page] || 1

    users =
      Accounts.list_users(socket.assigns.q, page(users_page))
      |> Enum.map(fn user ->
        %{
          user: user,
          tokens: Accounts.list_api_tokens(user),
          synced_groups: Mirror.groups_of(User.identity_keys(user)),
          identities: user.identity_account_ids || [],
          guard: guard(user)
        }
      end)

    assign(socket,
      users: users,
      users_page: users_page,
      users_total: Accounts.count_users(socket.assigns.q),
      service_tokens: Accounts.list_service_tokens(),
      administrators: administrators(),
      synced_groups: Mirror.synced_group_names()
    )
  end

  # A mirror can hold more accounts than one screen should draw; the screen
  # renders a page and says how many there are, instead of building every row.
  @page_size 25

  defp page(number), do: [limit: @page_size, offset: (number - 1) * @page_size]

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :param, :string, required: true

  @doc """
  "page 2 of 40 · 987 in total" with Previous/Next.

  A mirror can hold more accounts than one screen should draw, so the list never
  renders more than a page: the page number is a URL parameter and the query does
  the paging in the database.
  """
  def pager(assigns) do
    assigns = assign(assigns, :pages, Paging.page_count(assigns.total, @page_size))

    ~H"""
    <div :if={@pages > 1} id={@id} class="mt-3 flex flex-wrap items-center justify-between gap-2">
      <span class="text-[11px] text-base-content/70">
        page {@page} of {@pages} · {@total} in total
      </span>
      <div class="flex gap-1.5">
        <.link
          :if={@page > 1}
          patch={~p"/admin/users?#{page_params(@param, @page - 1)}"}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Previous
        </.link>
        <.link
          :if={@page < @pages}
          patch={~p"/admin/users?#{page_params(@param, @page + 1)}"}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Next
        </.link>
      </div>
    </div>
    """
  end

  defp page_params(param, page), do: [{param, page}]

  # Why this account cannot be demoted or switched off here, if it cannot.
  defp guard(user) do
    cond do
      Admins.protected?(user) -> :protected
      Accounts.last_admin?(user) -> :last_admin
      true -> nil
    end
  end

  defp guard_label(:protected), do: "Protected"
  defp guard_label(:last_admin), do: "Last admin"

  defp guard_note(:protected), do: "Seeded or bootstrap administrator"
  defp guard_note(:last_admin), do: "The last administrator — the mirror has to keep one"
  defp guard_note(nil), do: nil

  # What the flags mean for access, said plainly. "Switch on here" is not "let
  # them in": the site decides that, and a ban ignores it.
  defp access_note(%User{} = user, allow_site_disabled?) do
    cond do
      User.banned?(user) ->
        "Banned here: no access, and the account cannot be deleted until the ban is lifted."

      User.deleted_on_site?(user) ->
        "Confluence no longer has this account — access stays closed whatever this mirror says."

      User.disabled_on_site?(user) and allow_site_disabled? ->
        "Confluence switched this account off, but this mirror still lets switched-off readers in."

      User.disabled_on_site?(user) ->
        "Confluence switched this account off, and the mirror follows the site."

      true ->
        nil
    end
  end

  # A locked account can still be switched back on, so somebody who was
  # disabled before the guard existed is not stranded.
  defp can_toggle?(nil, _user), do: true
  defp can_toggle?(_guard, user), do: User.disabled_here?(user)

  # Why an action is not offered, asked of the same function `Accounts` refuses
  # with, so a button cannot promise something the event will reject.
  defp ban_note(%User{} = user) do
    case Accounts.ban_blocked(user) do
      nil -> nil
      {:error, :protected_admin} -> "A seeded or bootstrap administrator cannot be banned"
      {:error, :last_admin} -> "Banning a switch-off no sync undoes — #{guard_note(:last_admin)}"
    end
  end

  defp delete_note(%User{} = user) do
    case Accounts.deletion_blocked(user) do
      nil -> nil
      {:error, :protected_admin} -> "A seeded or bootstrap administrator cannot be deleted"
      {:error, :banned} -> "A banned account cannot be deleted — lift the ban first"
      {:error, :last_admin} -> guard_note(:last_admin)
    end
  end

  # Who Confluence says administers the mirror: the members of every configured
  # admin group, as the last sync read them. Listed separately from the accounts
  # because a Confluence administrator may never have signed in here.
  defp administrators do
    for group <- Admins.admin_groups() do
      %{group: group, members: Mirror.group_members(group)}
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
      page_title="Users &amp; tokens"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:users} />
      </:subnav>

      <.admin_header
        title="Users & tokens"
        subtitle="Accounts are mirror-local — no Confluence credentials are stored. Groups come from the last sync."
      >
        <:actions>
          <button
            type="button"
            id="sync-people"
            phx-click="sync_people"
            class="btn btn-ghost btn-sm gap-1"
            disabled={@paused?}
            title={
              if @paused?,
                do: "Confluence calls are paused — resume in Settings",
                else: "Read the site's groups and each account's status again — no page is read"
            }
          >
            <.icon name="hero-arrow-path" class="size-4" /> Re-read people
          </button>
        </:actions>
      </.admin_header>

      <.job_notice
        :if={@queued}
        job={@queued.job}
        what={@queued.what}
        id="users-job-queued"
      />

      <div :if={@new_token} class="mt-5 rounded-xl border border-success/40 bg-success/10 p-4">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="text-xs font-semibold text-success">New token for {@new_token.user}</p>
            <code class="mt-2 block select-all break-all rounded-lg bg-base-100 px-3 py-2 font-mono text-xs">
              {@new_token.token}
            </code>
            <p class="mt-2 text-[11px] text-base-content/70">
              Shown once. It is stored hashed and cannot be retrieved again.
            </p>
          </div>
          <button type="button" phx-click="dismiss_token" class="btn btn-ghost btn-xs">Dismiss</button>
        </div>
      </div>

      <div class="mt-6 grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_21rem]">
        <section class="overflow-hidden rounded-2xl border border-base-300/70 bg-base-100">
          <div class="flex items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3">
            <h2 class="text-sm font-semibold">Accounts</h2>
            <span class="badge badge-ghost badge-sm">{@users_total}</span>
          </div>

          <%!-- `phx-submit` is not decoration: without it Enter is a native
          form submit, which reloads the page and throws the filter away. --%>
          <form
            id="user-filter"
            phx-change="filter"
            phx-submit="filter"
            class="border-b border-base-300/70 px-5 py-3"
          >
            <input
              type="search"
              name="q"
              value={@q}
              phx-debounce="200"
              placeholder="Filter by e-mail or name"
              aria-label="Filter accounts"
              class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
            />
          </form>

          <p :if={@users == []} id="accounts-empty" class="px-5 py-8 text-sm text-base-content/70">
            No account matches this filter.
          </p>

          <article
            :for={
              %{
                user: user,
                tokens: tokens,
                synced_groups: synced_groups,
                identities: identities,
                guard: guard
              } <- @users
            }
            class="border-b border-base-300/60 px-5 py-4 last:border-b-0"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="flex min-w-0 items-center gap-3">
                <span class="grid size-9 shrink-0 place-items-center rounded-full bg-base-200 text-xs font-semibold uppercase">
                  {String.first(user.email)}
                </span>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-1.5">
                    <p class="truncate text-sm font-medium">{user.email}</p>
                    <span :if={Admins.source(user)} class="badge badge-primary badge-xs">
                      admin · {Admins.source(user)}
                    </span>
                    <span
                      :if={User.disabled_here?(user)}
                      id={"disabled-here-#{user.id}"}
                      class="badge badge-error badge-xs"
                    >
                      disabled here
                    </span>
                    <span
                      :if={User.disabled_on_site?(user)}
                      id={"disabled-on-site-#{user.id}"}
                      class="badge badge-warning badge-xs"
                    >
                      disabled on the site
                    </span>
                    <span
                      :if={User.deleted_on_site?(user)}
                      id={"deleted-on-site-#{user.id}"}
                      class="badge badge-error badge-xs"
                    >
                      deleted on the site
                    </span>
                    <span
                      :if={User.banned?(user)}
                      id={"banned-#{user.id}"}
                      class="badge badge-error badge-xs badge-outline"
                    >
                      banned
                    </span>
                  </div>
                  <p
                    :if={access_note(user, @allow_site_disabled?)}
                    class="mt-1 text-[11px] text-warning"
                  >
                    {access_note(user, @allow_site_disabled?)}
                  </p>
                  <p class="text-[11px] text-base-content/70">
                    {if user.last_sign_in_at,
                      do: "last seen #{Time.ago(user.last_sign_in_at)}",
                      else: "never signed in"}
                  </p>
                  <span
                    :if={User.provisioned?(user)}
                    id={"provisioned-#{user.id}"}
                    class="badge badge-ghost badge-xs"
                    title="The sync created this account because the site named this person"
                  >
                    from the sync
                  </span>
                </div>
              </div>

              <form phx-submit="change_role" class="flex items-center gap-1.5">
                <input type="hidden" name="user_id" value={user.id} />
                <select
                  name="role"
                  class="select select-sm select-bordered min-h-11 rounded-lg sm:min-h-0"
                  aria-label={"Role of #{user.email}"}
                  disabled={guard != nil}
                  title={guard_note(guard)}
                >
                  <option value="member" selected={user.role == "member"}>member</option>
                  <option value="admin" selected={user.role == "admin"}>admin</option>
                </select>
                <button
                  :if={guard}
                  type="button"
                  id={"role-locked-#{user.id}"}
                  class="btn btn-ghost btn-sm btn-disabled min-h-11 gap-1 sm:min-h-0"
                  title={guard_note(guard)}
                >
                  <.icon name="hero-lock-closed" class="size-3.5" /> {guard_label(guard)}
                </button>
                <button
                  :if={is_nil(guard)}
                  type="submit"
                  class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
                  data-confirm={user.role == "admin" && demotion_warning(user)}
                >
                  Save
                </button>
              </form>

              <form
                id={"disable-form-#{user.id}"}
                phx-submit="set_disabled"
                class="flex items-center gap-1.5"
              >
                <input type="hidden" name="user_id" value={user.id} />
                <input
                  type="hidden"
                  name="disabled"
                  value={to_string(not User.disabled_here?(user))}
                />
                <button
                  :if={can_toggle?(guard, user)}
                  type="submit"
                  id={"toggle-#{user.id}"}
                  class={[
                    "btn btn-sm min-h-11 sm:min-h-0",
                    if(User.disabled_here?(user),
                      do: "btn-success btn-outline",
                      else: "btn-warning btn-outline"
                    )
                  ]}
                  data-confirm={
                    if User.disabled_here?(user),
                      do:
                        "Lift this mirror's flag on #{user.email}? Confluence still has the last word, and a ban ignores it.",
                      else:
                        "Switch #{user.email} off here? They lose access immediately; Confluence is not changed."
                  }
                >
                  {if User.disabled_here?(user), do: "Switch on here", else: "Switch off here"}
                </button>
                <button
                  :if={not can_toggle?(guard, user)}
                  type="button"
                  id={"toggle-locked-#{user.id}"}
                  class="btn btn-sm btn-disabled min-h-11 gap-1 sm:min-h-0"
                  title={guard_note(guard)}
                >
                  <.icon name="hero-lock-closed" class="size-3.5" /> {guard_label(guard)}
                </button>
              </form>

              <form
                :if={User.banned?(user)}
                id={"unban-form-#{user.id}"}
                phx-submit="unban"
                class="flex items-center gap-1.5"
              >
                <input type="hidden" name="user_id" value={user.id} />
                <button
                  type="submit"
                  id={"unban-#{user.id}"}
                  class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
                >
                  Lift ban
                </button>
              </form>

              <form
                :if={not User.banned?(user)}
                id={"ban-form-#{user.id}"}
                phx-submit="ban"
                class="flex items-center gap-1.5"
              >
                <input type="hidden" name="user_id" value={user.id} />
                <button
                  :if={is_nil(ban_note(user))}
                  type="submit"
                  id={"ban-#{user.id}"}
                  class="btn btn-warning btn-outline btn-sm min-h-11 sm:min-h-0"
                  data-confirm={
                    "Ban #{user.email}? They lose access, no sync lifts it, and the account cannot be deleted until the ban is."
                  }
                >
                  Ban
                </button>
                <button
                  :if={ban_note(user)}
                  type="button"
                  id={"ban-locked-#{user.id}"}
                  class="btn btn-sm btn-disabled min-h-11 gap-1 sm:min-h-0"
                  title={ban_note(user)}
                >
                  <.icon name="hero-lock-closed" class="size-3.5" /> {guard_label(guard)}
                </button>
              </form>

              <% locked_note = delete_note(user) %>
              <form phx-submit="delete_user" class="flex items-center gap-1.5">
                <input type="hidden" name="user_id" value={user.id} />
                <button
                  type="submit"
                  id={"delete-#{user.id}"}
                  class={[
                    "btn btn-sm min-h-11 sm:min-h-0",
                    if(locked_note, do: "btn-disabled", else: "btn-error btn-outline")
                  ]}
                  disabled={locked_note != nil}
                  title={locked_note}
                  data-confirm={
                    "Delete #{user.email}, its tokens and its subscriptions? Confluence is not changed."
                  }
                >
                  Delete
                </button>
              </form>
            </div>

            <div class="mt-3 flex flex-wrap items-center gap-1.5">
              <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                Confluence groups
              </span>
              <span :for={group <- synced_groups} class="badge badge-ghost badge-xs">{group}</span>
              <span :if={synced_groups == []} class="text-[11px] text-base-content/70">
                none in the last sync
              </span>
            </div>

            <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
              <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                Linked identities
              </span>
              <span :for={identity <- identities} class="badge badge-outline badge-xs">
                {identity}
              </span>
              <span :if={identities == []} class="text-[11px] text-base-content/70">
                only the identity it signed in with
              </span>
              <%!-- Linking lives on the identities page, where both sides are
              searchable: this row only says what the account already holds. --%>
              <.link navigate={~p"/admin/identities"} class="link link-primary text-[11px]">
                Link an identity →
              </.link>
            </div>

            <%!-- Groups granted here sit on top of what the sync says: a
            membership Confluence does not have (an incident rotation, say),
            kept across syncs. The picker offers what the last sync read, so a
            grant is a name that exists rather than a typo that quietly does
            nothing; the free field is for a group no sync has seen yet. --%>
            <div class="mt-3">
              <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                Extra groups (granted here)
              </span>
              <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
                <span
                  :for={group <- user.groups || []}
                  class="badge badge-outline badge-sm gap-1"
                >
                  {group}
                  <form phx-submit="remove_group" class="inline">
                    <input type="hidden" name="user_id" value={user.id} />
                    <input type="hidden" name="group" value={group} />
                    <button
                      type="submit"
                      id={"remove-group-#{user.id}-#{group}"}
                      class="text-base-content/60 hover:text-error"
                      aria-label={"Stop granting #{group} to #{user.email}"}
                      title="Stop granting this group here"
                    >
                      ×
                    </button>
                  </form>
                </span>
                <span :if={user.groups in [nil, []]} class="text-[11px] text-base-content/70">
                  none
                </span>
              </div>

              <div class="mt-2 flex flex-wrap items-center gap-1.5">
                <form
                  phx-submit="add_group"
                  id={"group-picker-form-#{user.id}"}
                  class="flex items-center gap-1.5"
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <select
                    name="group"
                    id={"group-picker-#{user.id}"}
                    class="select select-sm min-h-11 rounded-lg sm:min-h-0"
                    aria-label={"Grant a synced group to #{user.email}"}
                  >
                    <option value="">grant a synced group…</option>
                    <option
                      :for={group <- @synced_groups -- (user.groups || [])}
                      value={group}
                    >
                      {group}
                    </option>
                  </select>
                  <button type="submit" class="btn btn-ghost btn-sm min-h-11 sm:min-h-0">
                    Grant
                  </button>
                </form>

                <form
                  phx-submit="add_group"
                  id={"group-free-form-#{user.id}"}
                  class="flex items-center gap-1.5"
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <input
                    type="text"
                    name="group"
                    id={"group-free-#{user.id}"}
                    placeholder="a group no sync has read"
                    class="input input-sm min-h-11 rounded-lg sm:min-h-0"
                    aria-label={"Grant another group to #{user.email}"}
                  />
                  <button type="submit" class="btn btn-ghost btn-sm min-h-11 sm:min-h-0">
                    Grant
                  </button>
                </form>
              </div>
              <p class="mt-1 text-[11px] text-base-content/70">
                Granted here only, and never taken away by a sync. It never removes a group
                Confluence says this person is in.
              </p>
            </div>

            <div class="mt-3 flex flex-wrap items-center gap-1.5">
              <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                API tokens
              </span>
              <span :if={tokens == []} class="text-[11px] text-base-content/70">
                none
              </span>
            </div>

            <%!-- A token acts as its owner, so an administrator cannot mint one:
            that would be this reader acting under somebody else's hand. The
            owner creates their own under /profile; what is left here is the
            emergency remedy — a leaked token can be revoked. --%>
            <ul :if={tokens != []} id={"tokens-#{user.id}"} class="mt-2 flex flex-wrap gap-2">
              <li
                :for={token <- tokens}
                class="flex items-center gap-2 rounded-lg border border-base-300/70 bg-base-200/40 px-2.5 py-1.5 text-[11px]"
              >
                <code class="font-mono">{token.token_prefix}…</code>
                <span class="max-w-[10rem] truncate">{token.name}</span>
                <span :if={token.last_used_at} class="text-base-content/70">
                  used {Time.ago(token.last_used_at)}
                </span>
                <form phx-submit="revoke_token" id={"revoke-token-form-#{token.id}"}>
                  <input type="hidden" name="user_id" value={user.id} />
                  <input type="hidden" name="token_id" value={token.id} />
                  <button
                    type="submit"
                    id={"revoke-token-#{token.id}"}
                    class="btn btn-ghost btn-xs min-h-11 text-error sm:min-h-0"
                    data-confirm={
                      "Revoke token “#{token.name}”? Anything using it stops working immediately."
                    }
                  >
                    Revoke token
                  </button>
                </form>
              </li>
            </ul>
            <p class="mt-2 text-[11px] text-base-content/70">
              {user.email} creates their own tokens under
              <.link navigate={~p"/profile?tab=tokens"} class="link link-primary">their account</.link>
              — a token is that person's secret.
            </p>
          </article>
        </section>

        <.pager
          id="accounts-pager"
          page={@users_page}
          total={@users_total}
          param="u_page"
        />

        <aside class="space-y-5">
          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">Account provisioning</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              A sync creates an account for every person Confluence names — an author, a group member — and
              will share an e-mail for. There is no account form; signing in only claims an existing row.
            </p>
            <ul class="mt-3 space-y-2 text-xs">
              <li class="flex items-start gap-2">
                <.icon
                  name="hero-arrow-right-on-rectangle"
                  class="mt-0.5 size-3.5 shrink-0 opacity-60"
                />
                <span :if={@proxy_auth?}>
                  Behind the proxy: the identity header
                  <code class="font-mono text-[11px]">{@proxy_header}</code>
                  provisions the account automatically.
                </span>
                <span :if={not @proxy_auth?}>
                  Through a magic link: an unknown address gets an account when self
                  sign-up is enabled.
                </span>
              </li>
              <li class="flex items-start gap-2">
                <.icon name="hero-user-group" class="mt-0.5 size-3.5 shrink-0 opacity-60" />
                <span>
                  Group membership is mirrored from Confluence by every sync; the members of
                  <code class="font-mono text-[11px]">{Enum.join(Admins.admin_groups(), ", ")}</code>
                  therefore administer the mirror.
                </span>
              </li>
              <li class="flex items-start gap-2">
                <.icon name="hero-lock-closed" class="mt-0.5 size-3.5 shrink-0 opacity-60" />
                <span>Seeded administrators and the bootstrap account stay protected.</span>
              </li>
            </ul>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">Administrators from Confluence</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              Members of the admin groups as the last sync read them. They do not need an account here.
            </p>

            <div :for={%{group: group, members: members} <- @administrators} class="mt-3">
              <div class="flex items-center gap-2">
                <span class="font-mono text-[11px] text-base-content/70">{group}</span>
                <span class="badge badge-ghost badge-xs">{length(members)}</span>
              </div>
              <ul class="mt-1.5 space-y-1">
                <li :for={member <- members} class="flex items-baseline gap-2 text-xs">
                  <span class="truncate">{member.display_name || member.subject_key}</span>
                  <span :if={member.email} class="truncate text-[11px] text-base-content/70">
                    {member.email}
                  </span>
                </li>
              </ul>
              <p :if={members == []} class="mt-1.5 text-[11px] text-base-content/70">
                No member of this group in the last sync.
              </p>
            </div>

            <p :if={@synced_groups != []} class="mt-3 text-[11px] text-base-content/70">
              Groups the last sync read: <code>{Enum.join(@synced_groups, ", ")}</code>
            </p>
            <p :if={@synced_groups == []} class="mt-3 text-[11px] text-base-content/70">
              No group membership has been synced yet — run a sync.
            </p>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <div>
              <h2 class="text-sm font-semibold">Service tokens</h2>
              <p class="mt-0.5 text-[11px] text-base-content/70">
                For integrations, not people. A <code>webhook</code>
                token is accepted as <code>X-Webhook-Token</code>
                on the Confluence webhook route and cannot open the API or the reader UI.
              </p>
            </div>

            <form
              id="create-service-token"
              phx-submit="create_service_token"
              class="mt-3 space-y-2"
            >
              <input
                type="text"
                name="name"
                placeholder="name, e.g. confluence-webhooks"
                required
                class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
              />
              <div class="flex gap-2">
                <select
                  name="scope"
                  class="select select-sm min-h-11 flex-1 rounded-lg sm:min-h-0"
                  aria-label="Token scope"
                >
                  <option value="webhook">webhook</option>
                </select>
                <button type="submit" class="btn btn-primary btn-sm min-h-11 sm:min-h-0">
                  Create
                </button>
              </div>
            </form>

            <ul :if={@service_tokens != []} class="mt-3 space-y-2">
              <li
                :for={token <- @service_tokens}
                class="flex items-center gap-2 rounded-lg border border-base-300/70 bg-base-200/40 px-3 py-2"
              >
                <div class="min-w-0 flex-1">
                  <p class="truncate text-xs font-medium">{token.name}</p>
                  <p class="text-[11px] text-base-content/70">
                    <code class="font-mono">{token.token_prefix}…</code>
                    · {token.scope} · {if token.last_used_at,
                      do: "used #{Time.ago(token.last_used_at)}",
                      else: "never used"}
                  </p>
                </div>
                <form phx-submit="revoke_service_token">
                  <input type="hidden" name="token_id" value={token.id} />
                  <button
                    type="submit"
                    class="btn btn-ghost btn-xs min-h-11 text-error sm:min-h-0"
                    data-confirm={
                      "Revoke token “#{token.name}”? Deliveries that use it are rejected from then on."
                    }
                  >
                    Revoke token
                  </button>
                </form>
              </li>
            </ul>
            <p :if={@service_tokens == []} class="mt-3 text-[11px] text-base-content/70">
              No service tokens yet.
            </p>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # A role is an access decision: say what the person loses before it happens.
  defp demotion_warning(user) do
    "Demote #{user.email} to member? They lose access to the admin screens immediately."
  end
end
