defmodule ConfluencePhxMirrorWeb.Admin.IdentitiesLive do
  @moduledoc """
  The Confluence identities the mirror knows, and the accounts they stand for.

  A mirror is not a user directory. Confluence Cloud lists no site users, and it
  stopped answering "who is in this group"; what the mirror does know is the
  people its content names — authors of pages and comments, and the account ids
  the permissions carry. This page is that list, and the one place an
  administrator says "this identity is this person".

  Linking is an access decision: what the identity may read becomes the
  account's, groups included. So the refusals are part of the screen — a name the
  mirror has never seen, or an identity another account already holds, is said in
  words rather than swallowed.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.PeopleWorker
  alias ConfluencePhxMirrorWeb.Admin.Paging

  @page_size 25
  @candidate_window 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       people_query: "",
       people_page: 1,
       paused?: Settings.sync_paused?(),
       queued: nil,
       account_pick: nil,
       account_query: "",
       account_results: nil,
       identity_pick: nil,
       pick_query: "",
       pick_results: nil,
       identity_query: "",
       identity_results: nil,
       page_title: "Confluence identities"
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(people_page: Paging.page_number(params["page"]), people_query: params["q"] || "")
     |> load()}
  end

  # Every event is a name and a handler, so this function reads as the table of
  # what the page can be asked to do.
  @impl true
  def handle_event("filter_identities", params, socket), do: filter_identities(params, socket)
  def handle_event("pick_account", params, socket), do: pick_account(params, socket)
  def handle_event("search_accounts", params, socket), do: search_accounts(params, socket)
  def handle_event("confirm_link", params, socket), do: confirm_link(params, socket)
  def handle_event("cancel_pick", params, socket), do: cancel_pick(params, socket)
  def handle_event("unlink_identity", params, socket), do: unlink_identity(params, socket)

  def handle_event("search_pick_accounts", params, socket),
    do: search_pick_accounts(params, socket)

  def handle_event("pick_identity", params, socket), do: pick_identity(params, socket)
  def handle_event("search_identity", params, socket), do: search_identity(params, socket)

  # Asking Confluence again is a run of its own: it reads who is in which group,
  # and no page at all. It is queued rather than awaited, because the answer is
  # seconds to minutes away and the screen has nothing to show until then.
  def handle_event("sync_people", _params, socket) do
    args = %{"trigger" => "the identities screen, by #{socket.assigns.current_user.email}"}

    case Sync.enqueue(PeopleWorker, args) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:queued, %{job: job, what: "A read of the site's groups and memberships"})
         |> put_flash(:info, "Reading the site's groups and memberships.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue it: #{inspect(reason)}")}
    end
  end

  # The search lives in the URL: a site can name a hundred thousand identities,
  # and a colleague should be able to send a link to the one they mean.
  defp filter_identities(%{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(people_query: query, people_page: 1)
     |> push_patch(to: ~p"/admin/identities?#{identity_params(query)}")}
  end

  defp identity_params(blank) when blank in [nil, ""], do: []
  defp identity_params(query), do: [q: query]

  defp pick_account(%{"account_id" => account_id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(account_pick: %{account_id: account_id, display_name: name})
     |> assign(account_query: "", account_results: nil)}
  end

  defp search_accounts(%{"q" => query}, socket) do
    {:noreply, assign(socket, account_query: query, account_results: account_candidates(query))}
  end

  defp cancel_pick(_params, socket) do
    {:noreply,
     socket
     |> assign(account_pick: nil)
     |> assign(account_query: "", account_results: nil)
     |> assign(identity_pick: nil)
     |> assign(identity_query: "", identity_results: nil)}
  end

  # The other direction: an administrator has an account in mind and asks what
  # the content knows about that person. The account is searched rather than
  # typed as an id, because nobody knows an id by heart.
  defp search_pick_accounts(%{"q" => query}, socket) do
    {:noreply, assign(socket, pick_query: query, pick_results: account_candidates(query))}
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

  defp search_identity(%{"q" => query}, socket) do
    {:noreply,
     assign(socket,
       identity_query: query,
       identity_results: identity_candidates(query, socket.assigns.identity_pick)
     )}
  end

  defp confirm_link(%{"account_id" => account_id, "user_id" => user_id}, socket) do
    case Accounts.get_user(String.to_integer(user_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That account is gone already.")}

      user ->
        case Accounts.link_identity(user, account_id, actor(socket)) do
          {:ok, user} ->
            {:noreply,
             socket
             |> assign(account_pick: nil)
             |> assign(account_query: "", account_results: nil)
             |> assign(identity_pick: nil)
             |> assign(identity_query: "", identity_results: nil)
             |> put_flash(
               :info,
               "#{account_id} is now #{user.email} — #{length(user.identity_account_ids)} linked."
             )
             |> load()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, link_refusal(reason, account_id))}
        end
    end
  end

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

  defp actor(socket), do: {:user, socket.assigns.current_user}

  # Accounts offered for an identity: the administrator's own search, capped, so
  # a mirror with thousands of accounts sends ten rows rather than all of them.
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

  # What the picker says under a candidate: how many further identities the
  # account already holds is the reason one row reads differently from another.
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

  # ---------------------------------------------------------------------------
  # What the page shows
  # ---------------------------------------------------------------------------

  defp load(socket) do
    page_number = socket.assigns[:people_page] || 1
    query = socket.assigns[:people_query] || ""

    assign(socket,
      people: people(page_number, query),
      people_page: page_number,
      people_total: Mirror.count_people(query: query)
    )
  end

  # The people Confluence's content names, marked when they have an account here
  # and which account stands for them. The site lists no users: the content says
  # who wrote it, and the sync asks the site which groups each of them is in.
  defp people(page_number, query) do
    offset = (page_number - 1) * @page_size

    page = Mirror.people(limit: @page_size, offset: offset, query: query)
    accounts = Accounts.users_by_identity(Enum.map(page, & &1.account_id))

    page
    |> Enum.map(fn person ->
      holder = Map.get(accounts, person.account_id)

      person
      |> Map.put(:account_email, holder && holder.email)
      |> Map.put(:account_id_here, holder && holder.id)
    end)
    |> Enum.with_index(offset + 1)
    |> Enum.map(fn {person, index} -> Map.put(person, :index, index) end)
  end

  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :query, :string, default: nil, doc: "the filter the page belongs to, kept across pages"

  # "page 2 of 40 · 987 in total" with Previous/Next. A filter travels with the
  # page numbers, or the second page would answer a different question than the
  # first.
  def pager(assigns) do
    assigns = assign(assigns, :pages, Paging.page_count(assigns.total, @page_size))

    ~H"""
    <div
      :if={@pages > 1}
      id="identities-pager"
      class="mt-3 flex flex-wrap items-center justify-between gap-2"
    >
      <span class="text-[11px] text-base-content/70">
        page {@page} of {@pages} · {@total} in total
      </span>
      <div class="flex gap-1.5">
        <.link
          :if={@page > 1}
          patch={identities_path(@page - 1, @query)}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Previous
        </.link>
        <.link
          :if={@page < @pages}
          patch={identities_path(@page + 1, @query)}
          class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
        >
          Next
        </.link>
      </div>
    </div>
    """
  end

  defp identities_path(page, blank) when blank in [nil, ""],
    do: ~p"/admin/identities?#{[page: page]}"

  defp identities_path(page, query), do: ~p"/admin/identities?#{[page: page, q: query]}"

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
      page_title="Confluence identities"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:identities} />
      </:subnav>

      <.admin_header
        title="Confluence identities"
        subtitle="The Atlassian accounts the content names, and the account each one stands for here."
      >
        <:actions>
          <button
            type="button"
            id="sync-identities"
            phx-click="sync_people"
            class="btn btn-outline btn-sm"
            disabled={@paused?}
            title={if @paused?, do: "Confluence calls are paused — resume in Settings"}
          >
            Sync with Confluence
          </button>
        </:actions>
      </.admin_header>

      <.job_notice
        :if={@queued}
        job={@queued.job}
        what={@queued.what}
        id="identities-job-queued"
      />

      <p :if={@paused?} id="identities-paused" class="mt-3 max-w-3xl text-xs">
        Confluence calls are paused, so memberships cannot be re-read now — these are the groups the
        last run stored. <a href={~p"/admin/settings"} class="link">Resume in Settings</a>.
      </p>

      <p class="mt-4 max-w-3xl text-xs text-base-content/70">
        Confluence Cloud lists no site users, so these are the identities the mirror has evidence
        of — the authors of pages and comments, and the account ids the permissions name. One person
        can hold two of them, a personal account and a guest one; linking says they are one person,
        and what the identity may read becomes that account's, groups included.
      </p>

      <section class="mt-4 overflow-hidden rounded-2xl border border-base-300/70 bg-base-100">
        <div class="flex items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3">
          <h2 class="text-sm font-semibold">People from Confluence</h2>
          <span class="badge badge-ghost badge-sm">{@people_total}</span>
        </div>

        <form
          id="identity-filter"
          phx-change="filter_identities"
          phx-submit="filter_identities"
          class="border-b border-base-300/70 px-5 py-3"
        >
          <input
            type="search"
            name="q"
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
          class="border-b border-base-300/70 bg-primary/5 px-5 py-4"
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

        <ul :if={@people != []} class="divide-y divide-base-300/60">
          <li :for={person <- @people} id={"person-#{person.index}"} class="px-5 py-3 text-xs">
            <div class="flex flex-wrap items-center gap-1.5">
              <span class="truncate font-medium">
                {person.display_name || person.account_id}
              </span>
              <span :if={person.account_email} class="badge badge-primary badge-xs">
                has an account
              </span>
              <span
                :if={is_nil(person.account_email)}
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
                  "No account stands for this identity yet. Link it to one and what it may read becomes that account's — including the groups it is in."}
            </p>
            <div class="mt-1 flex flex-wrap gap-1">
              <span :for={group <- person.groups} class="badge badge-ghost badge-xs">
                {group}
              </span>
              <span :if={person.groups == []} class="text-[11px] text-base-content/70">
                {groups_hint(person.groups)}
              </span>
            </div>

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

        <p :if={@people == []} class="px-5 py-8 text-sm text-base-content/70">
          No author mirrored yet — run a sync.
        </p>

        <div class="border-t border-base-300/70 px-5 py-3">
          <.pager page={@people_page} total={@people_total} query={@people_query} />
        </div>
      </section>

      <%!-- The other direction, for the administrator who has the account in
      mind and asks what the content knows about that person: search the account
      first, then pick the identity it should also hold. --%>
      <section class="mt-4 overflow-hidden rounded-2xl border border-base-300/70 bg-base-100">
        <div class="flex items-center justify-between gap-3 border-b border-base-300/70 px-5 py-3">
          <h2 class="text-sm font-semibold">Add an identity to an account</h2>
          <button
            :if={@identity_pick}
            type="button"
            phx-click="cancel_pick"
            id="cancel-identity-pick"
            class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
          >
            Close
          </button>
        </div>

        <div :if={is_nil(@identity_pick)} class="px-5 py-4">
          <p class="text-[11px] text-base-content/70">
            Search the account, then pick the identity that is also this person.
          </p>
          <form
            id="account-pick-form"
            phx-change="search_pick_accounts"
            phx-submit="search_pick_accounts"
            class="mt-2"
          >
            <input
              type="search"
              name="q"
              value={@pick_query}
              phx-debounce="200"
              placeholder="Search accounts by e-mail or name"
              aria-label="Search accounts to add an identity to"
              class="input input-sm min-h-11 w-full rounded-lg sm:min-h-0"
            />
          </form>

          <ul :if={@pick_results not in [nil, []]} class="mt-2 space-y-1.5">
            <li :for={%{user: candidate, identities: linked} <- @pick_results}>
              <button
                type="button"
                phx-click="pick_identity"
                phx-value-user_id={candidate.id}
                id={"link-identity-#{candidate.id}"}
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
            :if={@pick_results == []}
            id="no-account-picks"
            class="mt-2 text-[11px] text-base-content/70"
          >
            No account matches “{@pick_query}” — refine the search.
          </p>
        </div>

        <div :if={@identity_pick} id="identity-picker" class="px-5 py-4">
          <p class="text-xs font-semibold">
            Add an identity to <span class="font-medium">{@identity_pick.email}</span>
          </p>
          <p class="mt-0.5 text-[11px] text-base-content/70">
            Search what the content names, then click the one that is this person. A link makes
            everything that identity may read theirs, groups included — link two identities and it
            holds both.
          </p>

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
      </section>
    </Layouts.app>
    """
  end
end
