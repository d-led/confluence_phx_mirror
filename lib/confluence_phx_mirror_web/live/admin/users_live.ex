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
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.Time

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       new_token: nil,
       q: "",
       people_query: "",
       account_pick: nil,
       identity_pick: nil,
       account_query: "",
       account_results: nil,
       identity_query: "",
       identity_results: nil,
       proxy_auth?: Application.get_env(:confluence_phx_mirror, :proxy_auth, false),
       proxy_header:
         Application.get_env(:confluence_phx_mirror, :proxy_auth_header, "x-forwarded-email"),
       allow_site_disabled?:
         Application.get_env(:confluence_phx_mirror, :allow_site_disabled_readers, false),
       page_title: "Users & tokens"
     )
     |> load()}
  end

  # Every event is a name and a handler: the clauses are one line each, so this
  # function reads as the table of what the page can be asked to do.
  @impl true
  def handle_event("filter", params, socket), do: filter(params, socket)
  def handle_event("filter_identities", params, socket), do: filter_identities(params, socket)
  def handle_event("set_disabled", params, socket), do: set_disabled(params, socket)
  def handle_event("change_role", params, socket), do: change_role(params, socket)
  def handle_event("add_group", params, socket), do: add_group(params, socket)
  def handle_event("remove_group", params, socket), do: remove_group(params, socket)
  def handle_event("pick_account", params, socket), do: pick_account(params, socket)
  def handle_event("pick_identity", params, socket), do: pick_identity(params, socket)
  def handle_event("search_accounts", params, socket), do: search_accounts(params, socket)
  def handle_event("search_identity", params, socket), do: search_identity(params, socket)
  def handle_event("confirm_link", params, socket), do: confirm_link(params, socket)
  def handle_event("cancel_pick", params, socket), do: cancel_pick(params, socket)
  def handle_event("unlink_identity", params, socket), do: unlink_identity(params, socket)
  def handle_event("unban", params, socket), do: unban(params, socket)
  def handle_event("ban", params, socket), do: ban(params, socket)
  def handle_event("delete_user", params, socket), do: delete_user(params, socket)

  def handle_event("create_service_token", params, socket),
    do: create_service_token(params, socket)

  def handle_event("revoke_service_token", params, socket),
    do: revoke_service_token(params, socket)

  def handle_event("revoke_token", params, socket), do: revoke_token(params, socket)
  def handle_event("dismiss_token", params, socket), do: dismiss_token(params, socket)

  defp filter(%{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: q, users_page: 1) |> load()}

  # The identity search lives in the URL: a page of a hundred thousand
  # identities is only useful if the one you mean can be linked to.
  defp filter_identities(%{"pq" => query}, socket) do
    {:noreply,
     socket
     |> assign(people_query: query, people_page: 1)
     |> push_patch(to: ~p"/admin/users?#{identity_params(query)}")}
  end

  defp identity_params(blank) when blank in [nil, ""], do: []
  defp identity_params(query), do: [pq: query]

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       users_page: page_number(params["u_page"]),
       people_page: page_number(params["p_page"]),
       people_query: params["pq"] || ""
     )
     |> load()}
  end

  defp page_number(nil), do: 1

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _not_a_page -> 1
    end
  end

  defp page_number(value) when is_integer(value) and value > 0, do: value

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

  # Linking is two searches and two clicks, in either direction: from an identity
  # to the account that should hold it, or from an account to the identities it
  # should hold. Neither side ever asks for an address to be typed in full — a
  # mirror may name a hundred thousand identities, and nobody knows an account id
  # by heart.
  defp pick_account(%{"account_id" => account_id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(account_pick: %{account_id: account_id, display_name: name}, identity_pick: nil)
     |> assign(account_query: "", account_results: nil)}
  end

  defp pick_identity(%{"user_id" => user_id}, socket) do
    case Accounts.get_user(String.to_integer(user_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That account is gone already.")}

      user ->
        {:noreply,
         socket
         |> assign(identity_pick: user, account_pick: nil)
         |> assign(identity_query: "", identity_results: identity_candidates("", user))}
    end
  end

  defp search_accounts(%{"q" => query}, socket) do
    {:noreply, assign(socket, account_query: query, account_results: account_candidates(query))}
  end

  defp search_identity(%{"q" => query}, socket) do
    {:noreply,
     assign(socket,
       identity_query: query,
       identity_results: identity_candidates(query, socket.assigns.identity_pick)
     )}
  end

  defp cancel_pick(_params, socket) do
    {:noreply,
     socket
     |> assign(account_pick: nil, identity_pick: nil)
     |> assign(account_query: "", account_results: nil, identity_query: "", identity_results: nil)}
  end

  defp confirm_link(%{"account_id" => account_id, "user_id" => user_id}, socket) do
    with_user(socket, user_id, fn user ->
      case Accounts.link_identity(user, account_id, actor(socket)) do
        {:ok, user} ->
          socket
          |> assign(account_pick: nil, identity_pick: nil)
          |> put_flash(
            :info,
            "#{account_id} is now #{user.email} — #{length(user.identity_account_ids)} linked."
          )
          |> load()

        {:error, reason} ->
          put_flash(socket, :error, link_refusal(reason, account_id))
      end
    end)
  end

  # Accounts offered for an identity: the administrator's own search, capped, so
  # a mirror with thousands of accounts sends ten rows rather than all of them.
  @candidate_window 8

  defp account_candidates(query) do
    query
    |> Accounts.list_users(limit: @candidate_window)
    |> Enum.map(&%{user: &1, identities: length(&1.identity_account_ids || [])})
  end

  # Identities offered for an account: only the ones no account holds yet are
  # clickable — the others say whose they are, because moving one is a decision
  # about two accounts and is not a side effect of this picker.
  defp identity_candidates(query, %User{} = user) do
    [limit: @candidate_window, query: query]
    |> Mirror.people()
    |> Enum.map(&Map.put(&1, :holder, holder_of(&1.account_id)))
    |> Enum.reject(
      &(&1.account_id in [user.confluence_account_id | user.identity_account_ids || []])
    )
  end

  defp identity_candidates(_query, nil), do: []

  defp holder_of(account_id) do
    case Accounts.accounts_linked_to(account_id) do
      [user | _] -> user.email
      [] -> nil
    end
  end

  # What the picker says under an identity it can offer: the groups the link
  # would bring, which is the reason an administrator picks one over another.
  defp groups_hint([]), do: "no groups synced"
  defp groups_hint(nil), do: "no groups synced"
  defp groups_hint(groups), do: "groups: " <> Enum.join(groups, ", ")

  # Why linking was refused, said the way an administrator can act on it: whose
  # the identity is, or that the site has not shown it yet.
  @refusals %{
    blank: "Pick an account first.",
    already_linked: "That identity already belongs to this account.",
    not_authorized: "Only an administrator may link identities."
  }

  defp link_refusal(reason, _account_id) when is_map_key(@refusals, reason),
    do: Map.fetch!(@refusals, reason)

  defp link_refusal({:linked_elsewhere, other}, account_id),
    do: "#{account_id} belongs to #{other.email}. Unlink it there first."

  defp link_refusal(:unknown_identity, account_id),
    do: "The mirror has not seen #{account_id} yet — run a sync."

  defp link_refusal(_reason, _account_id), do: "Could not link that identity."

  defp unlink_identity(%{"account_id" => account_id}, socket) do
    case Accounts.accounts_linked_to(account_id) do
      [user | _] ->
        case Accounts.unlink_identity(user, account_id, actor(socket)) do
          {:ok, user} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{account_id} is no longer #{user.email}'s.")
             |> load()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not unlink that identity.")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "No account stands for that identity.")}
    end
  end

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
    people_page = socket.assigns[:people_page] || 1

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
      people: people(people_page, people_query(socket)),
      people_page: people_page,
      people_total: Mirror.count_people(query: people_query(socket)),
      service_tokens: Accounts.list_service_tokens(),
      administrators: administrators(),
      synced_groups: Mirror.synced_group_names()
    )
  end

  defp people_query(socket), do: socket.assigns[:people_query] || ""

  # A site can name a hundred thousand people; the screen draws a page and says
  # how many there are, instead of building a hundred thousand rows.
  @page_size 25

  defp page(number), do: [limit: @page_size, offset: (number - 1) * @page_size]

  defp page_count(total), do: max(ceil(total / @page_size), 1)

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :param, :string, required: true
  attr :query, :string, default: nil, doc: "the filter the page belongs to, kept across pages"

  @doc """
  "page 2 of 40 · 987 in total" with Previous/Next.

  A site can name a hundred thousand people, so the list never renders more
  than one page: the page number is a URL parameter, the query pages in the
  database, and this says how much is left unseen. A filter travels with the
  page numbers, or the second page would answer a different question than the
  first.
  """
  def pager(assigns) do
    assigns = assign(assigns, :pages, page_count(assigns.total))

    ~H"""
    <div :if={@pages > 1} id={@id} class="mt-3 flex flex-wrap items-center justify-between gap-2">
      <span class="text-[11px] text-base-content/70">
        page {@page} of {@pages} · {@total} in total
      </span>
      <div class="flex gap-1.5">
        <.link
          :if={@page > 1}
          patch={~p"/admin/users?#{page_params(@param, @page - 1, @query)}"}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Previous
        </.link>
        <.link
          :if={@page < @pages}
          patch={~p"/admin/users?#{page_params(@param, @page + 1, @query)}"}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Next
        </.link>
      </div>
    </div>
    """
  end

  defp page_params(param, page, blank) when blank in [nil, ""], do: [{param, page}]
  defp page_params(param, page, query), do: [{param, page}, {:pq, query}]

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

  # The people Confluence's content names, marked when they have an account
  # here and which account stands for them. The site lists no users: the content
  # says who wrote it, and the sync asks the site which groups each of them is
  # in.
  defp people(page_number, query) do
    offset = (page_number - 1) * @page_size

    page = Mirror.people(limit: @page_size, offset: offset, query: query)
    accounts = Accounts.accounts_by_identity(Enum.map(page, & &1.account_id))

    page
    |> Enum.map(fn person ->
      person
      |> Map.put(:account_email, Map.get(accounts, person.account_id))
      |> Map.put(:account?, Map.has_key?(accounts, person.account_id))
    end)
    |> Enum.with_index(offset + 1)
    |> Enum.map(fn {person, index} -> Map.put(person, :index, index) end)
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
      <.admin_header
        current={:users}
        title="Users & tokens"
        subtitle="Accounts are mirror-local — no Confluence credentials are stored. Groups come from the last sync."
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

          <div
            :if={@identity_pick}
            id="identity-picker"
            class="border-b border-base-300/70 bg-primary/5 px-5 py-4"
          >
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0">
                <p class="text-xs font-semibold">
                  Add an identity to <span class="font-medium">{@identity_pick.email}</span>
                </p>
                <p class="mt-0.5 text-[11px] text-base-content/70">
                  Search what the content names, then click the one that is this person. A link
                  makes everything that identity may read theirs, groups included — link two
                  identities and it holds both.
                </p>
              </div>
              <button
                type="button"
                phx-click="cancel_pick"
                id="cancel-identity-pick"
                class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
              >
                Close
              </button>
            </div>

            <form
              id="identity-search-form"
              phx-change="search_identity"
              phx-submit="search_identity"
              class="mt-2"
            >
              <input
                type="search"
                name="q"
                value={@identity_query}
                phx-debounce="200"
                placeholder="Search identities by name or account id"
                aria-label="Search identities to link"
                class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
              />
            </form>

            <ul :if={@identity_results not in [nil, []]} class="mt-2 space-y-1.5">
              <li
                :for={candidate <- @identity_results}
                class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-base-300/60 bg-base-100 px-3 py-2"
              >
                <div class="min-w-0">
                  <p class="truncate text-xs font-medium">
                    {candidate.display_name || candidate.account_id}
                  </p>
                  <p class="font-mono text-[10px] text-base-content/50">
                    {candidate.account_id}
                  </p>
                  <p class="text-[11px] text-base-content/70">
                    {if candidate.holder,
                      do: "already #{candidate.holder}'s — unlink it there first",
                      else: groups_hint(candidate.groups)}
                  </p>
                </div>
                <button
                  :if={is_nil(candidate.holder)}
                  type="button"
                  phx-click="confirm_link"
                  phx-value-account_id={candidate.account_id}
                  phx-value-user_id={@identity_pick.id}
                  id={"link-candidate-#{candidate.account_id}"}
                  class="btn btn-primary btn-xs min-h-11 sm:min-h-0"
                >
                  Link
                </button>
              </li>
            </ul>
            <p
              :if={@identity_results == []}
              id="no-identity-candidates"
              class="mt-2 text-[11px] text-base-content/70"
            >
              {if @identity_query == "",
                do: "Nothing left to link here — the content has named nobody else yet.",
                else: "No identity matches “#{@identity_query}”."}
            </p>
          </div>

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
              <button
                type="button"
                phx-click="pick_identity"
                phx-value-user_id={user.id}
                id={"link-identity-#{user.id}"}
                class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
              >
                Link an identity…
              </button>
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
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-sm font-semibold">People from Confluence</h2>
              <span class="badge badge-ghost badge-xs">{@people_total}</span>
            </div>
            <p class="mt-1 text-[11px] text-base-content/70">
              Every Atlassian account the content or a group names — one person can have two of them
              (a personal account and a guest one), and they are two identities here until an
              administrator says they are one person.
            </p>

            <%!-- A site can name a hundred thousand identities: they are searched,
            never listed. The search is a URL parameter, so a colleague can send
            a link to the one they mean. --%>
            <form
              id="identity-filter"
              phx-change="filter_identities"
              phx-submit="filter_identities"
              class="mt-3"
            >
              <input
                type="search"
                name="pq"
                value={@people_query}
                phx-debounce="200"
                placeholder="Search by name or account id"
                aria-label="Search identities"
                class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
              />
            </form>

            <div
              :if={@account_pick}
              id="account-picker"
              class="mt-3 rounded-xl border border-primary/40 bg-primary/5 p-3"
            >
              <div class="flex items-start justify-between gap-2">
                <p class="text-xs font-semibold">
                  Link <span class="font-mono">{@account_pick.account_id}</span>
                  <span :if={@account_pick.display_name} class="font-medium">
                    ({@account_pick.display_name})
                  </span>
                  to an account
                </p>
                <button
                  type="button"
                  phx-click="cancel_pick"
                  id="cancel-account-pick"
                  class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
                >
                  Close
                </button>
              </div>

              <form
                id="account-search-form"
                phx-change="search_accounts"
                phx-submit="search_accounts"
                class="mt-2"
              >
                <input
                  type="search"
                  name="q"
                  value={@account_query}
                  phx-debounce="200"
                  placeholder="Search accounts by e-mail or name"
                  aria-label="Search accounts"
                  class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
                />
              </form>

              <ul :if={@account_results not in [nil, []]} class="mt-2 space-y-1.5">
                <li :for={%{user: candidate, identities: linked} <- @account_results}>
                  <button
                    type="button"
                    phx-click="confirm_link"
                    phx-value-account_id={@account_pick.account_id}
                    phx-value-user_id={candidate.id}
                    id={"link-account-#{candidate.id}"}
                    class="flex w-full items-center justify-between gap-2 rounded-lg border border-base-300/60 bg-base-100 px-3 py-2 text-left text-xs transition hover:border-primary/40 hover:text-primary"
                  >
                    <span class="truncate">{candidate.email}</span>
                    <span class="shrink-0 text-[11px] text-base-content/70">
                      {candidate.role} · {linked} linked
                    </span>
                  </button>
                </li>
              </ul>
              <p
                :if={@account_results == []}
                id="no-account-candidates"
                class="mt-2 text-[11px] text-base-content/70"
              >
                No account matches “{@account_query}” — refine the search.
              </p>
            </div>

            <ul :if={@people != []} class="mt-3 space-y-2.5">
              <li :for={person <- @people} id={"person-#{person.index}"} class="text-xs">
                <div class="flex flex-wrap items-center gap-1.5">
                  <span class="truncate font-medium">
                    {person.display_name || person.account_id}
                  </span>
                  <span :if={person.account?} class="badge badge-primary badge-xs">
                    has an account
                  </span>
                  <span
                    :if={not person.account?}
                    id={"person-no-account-#{person.index}"}
                    class="badge badge-ghost badge-xs"
                  >
                    not a mirror account
                  </span>
                </div>
                <p class="mt-0.5 font-mono text-[10px] text-base-content/50">
                  {person.account_id}
                </p>
                <p class="mt-0.5 text-[11px] text-base-content/70">
                  {if person.account_email,
                    do: "This identity is #{person.account_email}: what it may read is theirs.",
                    else:
                      "No account stands for this identity yet. Link it to one below and what it may read becomes that account's — including the groups it is in."}
                </p>
                <div class="mt-1 flex flex-wrap gap-1">
                  <span :for={group <- person.groups} class="badge badge-ghost badge-xs">
                    {group}
                  </span>
                  <span :if={person.groups == []} class="text-[11px] text-base-content/70">
                    no groups synced
                  </span>
                </div>

                <%!-- One person, several Atlassian accounts: the personal one
                and the guest one are two identities and the content may name
                either. Linking says "this identity is this account", and what
                the identity may read becomes the account's. --%>
                <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
                  <span :if={person.account_email} class="text-[11px] text-base-content/70">
                    linked to <span class="font-medium">{person.account_email}</span>
                  </span>
                  <form
                    :if={person.account_email}
                    phx-submit="unlink_identity"
                    id={"unlink-#{person.index}"}
                  >
                    <input type="hidden" name="account_id" value={person.account_id} />
                    <button
                      type="submit"
                      class="btn btn-ghost btn-xs min-h-11 text-error sm:min-h-0"
                      data-confirm={
                        "Unlink #{person.account_id} from #{person.account_email}? What this identity may read stops being theirs."
                      }
                    >
                      Unlink
                    </button>
                  </form>

                  <button
                    :if={is_nil(person.account_email)}
                    type="button"
                    phx-click="pick_account"
                    phx-value-account_id={person.account_id}
                    phx-value-name={person.display_name || ""}
                    id={"link-#{person.index}"}
                    class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
                  >
                    Link to an account…
                  </button>
                </div>
              </li>
            </ul>
            <p :if={@people == []} class="mt-2 text-[11px] text-base-content/70">
              No author mirrored yet — run a sync.
            </p>
            <.pager
              id="people-pager"
              page={@people_page}
              total={@people_total}
              param="p_page"
              query={@people_query}
            />
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
