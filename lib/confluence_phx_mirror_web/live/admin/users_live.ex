defmodule ConfluencePhxMirrorWeb.Admin.UsersLive do
  @moduledoc "Reader accounts and API tokens."

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Admins, User}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.Time

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       new_token: nil,
       proxy_auth?: Application.get_env(:confluence_phx_mirror, :proxy_auth, false),
       proxy_header:
         Application.get_env(:confluence_phx_mirror, :proxy_auth_header, "x-forwarded-email"),
       page_title: "Users & tokens"
     )
     |> load()}
  end

  @impl true
  def handle_event("change_role", %{"user_id" => user_id, "role" => role}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))

    case Accounts.change_role(user, role, actor(socket)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Role updated.") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not update the role.")}
    end
  end

  def handle_event("update_groups", %{"user_id" => user_id, "groups" => groups}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))
    groups = String.split(groups, ",", trim: true)

    case Accounts.update_groups(user, groups, actor(socket)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Groups updated.") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not update the groups.")}
    end
  end

  def handle_event("create_service_token", %{"name" => name, "scope" => scope}, socket) do
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

  def handle_event("revoke_service_token", %{"token_id" => token_id}, socket) do
    case Accounts.revoke_service_token(String.to_integer(token_id), actor(socket)) do
      :ok -> {:noreply, socket |> put_flash(:info, "Service token revoked.") |> load()}
      _ -> {:noreply, put_flash(socket, :error, "Service token not found.")}
    end
  end

  def handle_event("create_token", %{"user_id" => user_id, "name" => name}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))

    case Accounts.create_api_token(user, String.trim(name), actor(socket)) do
      {:ok, plain, _token} ->
        {:noreply,
         socket
         |> assign(new_token: %{user: user.email, token: plain})
         |> put_flash(:info, "Token created — copy it now, it is shown once.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create token: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke_token", %{"user_id" => user_id, "token_id" => token_id}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))

    case Accounts.revoke_api_token(user, String.to_integer(token_id), actor(socket)) do
      :ok -> {:noreply, socket |> put_flash(:info, "Token revoked.") |> load()}
      _ -> {:noreply, put_flash(socket, :error, "Token not found.")}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, new_token: nil)}
  end

  defp actor(%{assigns: %{current_user: user}}), do: {:user, user}

  defp load(socket) do
    users =
      Accounts.list_users()
      |> Enum.map(fn user ->
        %{
          user: user,
          tokens: Accounts.list_api_tokens(user),
          synced_groups: Mirror.groups_of(User.identity_keys(user))
        }
      end)

    assign(socket,
      users: users,
      service_tokens: Accounts.list_service_tokens(),
      administrators: administrators()
    )
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
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_source={@mirror_source}
      page_title="Users &amp; tokens"
      sidebar?={false}
    >
      <header class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300/70 pb-5">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">
            Administration
          </p>
          <h1 class="mt-1 text-3xl font-semibold">Users &amp; tokens</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Accounts are mirror-local — no Confluence credentials are stored. Groups come from the last sync.
          </p>
        </div>
        <.link navigate={~p"/admin"} class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-left" class="size-4" /> Dashboard
        </.link>
      </header>

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
            <span class="badge badge-ghost badge-sm">{length(@users)}</span>
          </div>

          <article
            :for={%{user: user, tokens: tokens, synced_groups: synced_groups} <- @users}
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
                  </div>
                  <p class="text-[11px] text-base-content/70">
                    {if user.last_sign_in_at,
                      do: "last seen #{Time.ago(user.last_sign_in_at)}",
                      else: "never signed in"}
                  </p>
                </div>
              </div>

              <form phx-submit="change_role" class="flex items-center gap-1.5">
                <input type="hidden" name="user_id" value={user.id} />
                <select
                  name="role"
                  class="select select-sm select-bordered min-h-11 rounded-lg sm:min-h-0"
                  aria-label={"Role of #{user.email}"}
                  disabled={Admins.protected?(user)}
                  title={Admins.protected?(user) && "Seeded or bootstrap administrator"}
                >
                  <option value="member" selected={user.role == "member"}>member</option>
                  <option value="admin" selected={user.role == "admin"}>admin</option>
                </select>
                <button
                  :if={Admins.protected?(user)}
                  type="button"
                  class="btn btn-ghost btn-sm btn-disabled min-h-11 gap-1 sm:min-h-0"
                  title="Seeded or bootstrap administrator"
                >
                  <.icon name="hero-lock-closed" class="size-3.5" /> Protected
                </button>
                <button
                  :if={not Admins.protected?(user)}
                  type="submit"
                  class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
                  data-confirm={user.role == "admin" && demotion_warning(user)}
                >
                  Save
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

            <div class="mt-3 grid gap-3 sm:grid-cols-2">
              <form phx-submit="update_groups" class="flex items-end gap-1.5">
                <input type="hidden" name="user_id" value={user.id} />
                <label class="min-w-0 flex-1">
                  <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                    Extra groups (granted here)
                  </span>
                  <input
                    type="text"
                    name="groups"
                    value={Enum.join(user.groups || [], ", ")}
                    placeholder="e.g. incident-responders"
                    class="input input-sm mt-1 min-h-11 w-full rounded-lg sm:min-h-0"
                    aria-label={"Extra groups of #{user.email}"}
                  />
                </label>
                <button type="submit" class="btn btn-ghost btn-sm min-h-11 sm:min-h-0">
                  Save
                </button>
              </form>

              <form
                id={"new-token-#{user.id}"}
                phx-submit="create_token"
                class="flex items-end gap-1.5"
              >
                <input type="hidden" name="user_id" value={user.id} />
                <label class="min-w-0 flex-1">
                  <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                    Token name
                  </span>
                  <input
                    type="text"
                    name="name"
                    placeholder="token name"
                    class="input input-sm mt-1 min-h-11 w-full rounded-lg sm:min-h-0"
                    required
                  />
                </label>
                <button type="submit" class="btn btn-outline btn-sm min-h-11 sm:min-h-0">
                  Create
                </button>
              </form>
            </div>

            <ul :if={tokens != []} class="mt-3 flex flex-wrap gap-2">
              <li
                :for={token <- tokens}
                class="flex items-center gap-2 rounded-lg border border-base-300/70 bg-base-200/40 px-2.5 py-1.5 text-[11px]"
              >
                <code class="font-mono">{token.token_prefix}…</code>
                <span class="max-w-[10rem] truncate">{token.name}</span>
                <span :if={token.last_used_at} class="text-base-content/70">
                  used {Time.ago(token.last_used_at)}
                </span>
                <form phx-submit="revoke_token">
                  <input type="hidden" name="user_id" value={user.id} />
                  <input type="hidden" name="token_id" value={token.id} />
                  <button
                    type="submit"
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
            <p :if={tokens == []} class="mt-3 text-[11px] text-base-content/70">
              No personal tokens.
            </p>
          </article>
        </section>

        <aside class="space-y-5">
          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">Account provisioning</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              Accounts are created on first sign-in — there is no account form.
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
                <span class="font-mono text-[11px] text-base-content/60">{group}</span>
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
                No members synced yet — run a sync.
              </p>
            </div>
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
