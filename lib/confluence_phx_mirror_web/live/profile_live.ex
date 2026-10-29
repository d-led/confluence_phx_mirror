defmodule ConfluencePhxMirrorWeb.ProfileLive do
  @moduledoc """
  A reader's own account, and the only place a personal API token is minted.

  Tokens are the reader's own secret: a token minted by somebody else is that
  somebody acting as this reader, which is not a thing an administrator may do.
  So the two halves of this page belong together —

    * **Profile**: what the mirror knows about this account, and which groups it
      is in (mirrored from Confluence, plus any an administrator granted here);
    * **API tokens**: the reader creates and revokes their own, and sees the
      secret exactly once.

  The tab lives in the URL (`?tab=tokens`), so a link to "my tokens" is a link
  someone can send themselves.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Admins, User}
  alias ConfluencePhxMirror.{Mail, Mirror}
  alias ConfluencePhxMirrorWeb.Time

  @tabs ~w(profile tokens)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:new_token, nil) |> assign_tab("profile") |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_tab(socket, params["tab"])}
  end

  defp assign_tab(socket, tab) when tab in @tabs, do: assign(socket, :tab, tab)
  defp assign_tab(socket, _tab), do: assign(socket, :tab, "profile")

  @impl true
  def handle_event("create_token", %{"name" => name}, socket) do
    user = socket.assigns.current_user

    case Accounts.create_api_token(user, String.trim(name), {:user, user}) do
      {:ok, plain, token} ->
        {:noreply,
         socket
         |> assign(new_token: %{name: token.name, token: plain})
         |> put_flash(:info, "Token created — copy it now, it is shown once.")
         |> load()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Give the token a name first.")}
    end
  end

  def handle_event("revoke_token", %{"token_id" => token_id}, socket) do
    user = socket.assigns.current_user

    case Accounts.revoke_api_token(user, String.to_integer(token_id), {:user, user}) do
      :ok -> {:noreply, socket |> put_flash(:info, "Token revoked.") |> load()}
      _ -> {:noreply, put_flash(socket, :error, "That token is gone already.")}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  # The one thing on this page that leaves the mirror, and the only way a reader
  # can find out that mail from here does not reach them.
  def handle_event("send_test_mail", _params, socket) do
    case Mail.send_test(socket.assigns.current_user) do
      :ok ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Test e-mail sent to #{socket.assigns.current_user.email} — it is from the same sender as your updates."
         )}

      {:error, :too_soon, retry_after_ms} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You sent yourself one a moment ago. Try again in #{seconds(retry_after_ms)}."
         )}

      {:error, :paused} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Mail is paused on this mirror, so nothing can be sent right now."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "The mail server refused it: #{inspect(reason)}")}
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    assign(socket,
      page_title: "Your account",
      tokens: Accounts.list_api_tokens(user),
      synced_groups: Mirror.groups_of(User.identity_keys(user)),
      granted_groups: user.groups || [],
      admin_source: Admins.source(user)
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
      page_title="Your account"
      sidebar?={false}
    >
      <div class="mx-auto w-full max-w-3xl px-3 py-6 sm:px-5">
        <h1 class="text-xl font-semibold">Your account</h1>
        <p class="mt-1 text-sm text-base-content/70">
          {@current_user.email}
        </p>

        <nav class="mt-4 flex gap-1 border-b border-base-300/70" aria-label="Account sections">
          <.tab_link tab="profile" current={@tab} label="Profile" icon="hero-user" />
          <.tab_link tab="tokens" current={@tab} label="API tokens" icon="hero-key" />
        </nav>

        <section :if={@tab == "profile"} id="profile-panel" class="mt-5 space-y-4">
          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">This account</h2>
            <dl class="mt-3 space-y-2 text-xs">
              <div class="flex items-baseline justify-between gap-3">
                <dt class="text-base-content/70">E-mail</dt>
                <dd class="truncate font-medium">{@current_user.email}</dd>
              </div>
              <div class="flex items-baseline justify-between gap-3">
                <dt class="text-base-content/70">Role</dt>
                <dd class="font-medium">
                  {@current_user.role}
                  <span :if={@admin_source} class="badge badge-primary badge-xs ml-1">
                    administrator · {@admin_source}
                  </span>
                </dd>
              </div>
              <div class="flex items-baseline justify-between gap-3">
                <dt class="text-base-content/70">Last signed in</dt>
                <dd class="font-medium">
                  {if @current_user.last_sign_in_at,
                    do: Time.ago(@current_user.last_sign_in_at),
                    else: "not recorded yet"}
                </dd>
              </div>
            </dl>
            <p class="mt-3 text-[11px] text-base-content/70">
              Accounts are mirror-local: no Confluence password is ever stored, and the name
              and e-mail come from the identity you signed in with.
            </p>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">Groups</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              A group is what grants access: space permissions and page restrictions name
              groups, so these decide what you can open.
            </p>

            <p class="mt-3 text-[11px] font-medium uppercase tracking-wider text-base-content/70">
              From the last sync
            </p>
            <div class="mt-1.5 flex flex-wrap gap-1.5">
              <span :for={group <- @synced_groups} class="badge badge-ghost badge-sm">{group}</span>
              <span :if={@synced_groups == []} class="text-[11px] text-base-content/70">
                none — your Confluence membership has not been synced
              </span>
            </div>

            <p class="mt-3 text-[11px] font-medium uppercase tracking-wider text-base-content/70">
              Granted on this mirror
            </p>
            <div class="mt-1.5 flex flex-wrap gap-1.5">
              <span :for={group <- @granted_groups} class="badge badge-outline badge-sm">
                {group}
              </span>
              <span :if={@granted_groups == []} class="text-[11px] text-base-content/70">
                none
              </span>
            </div>
            <p class="mt-3 text-[11px] text-base-content/70">
              An administrator changes these; you cannot grant yourself a group.
            </p>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">Watching</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              Pages and spaces you watch are listed in the e-mails you receive; stop watching
              from the page itself.
            </p>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">E-mail</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              Sign-in links and watchers' updates are sent from this mirror. If they do not
              arrive, nothing else on this page will tell you — so send yourself one message and
              see. It goes to {@current_user.email} only.
            </p>
            <button
              type="button"
              id="send-test-mail"
              phx-click="send_test_mail"
              class="btn btn-sm mt-3 min-h-11 gap-1.5 rounded-lg sm:min-h-0"
            >
              <.icon name="hero-paper-airplane" class="h-4 w-4" /> Send me a test e-mail
            </button>
            <p class="mt-1 text-[11px] text-base-content/70">One a minute.</p>
          </div>
        </section>

        <section :if={@tab == "tokens"} id="tokens-panel" class="mt-5 space-y-4">
          <div
            :if={@new_token}
            id="new-token"
            class="rounded-xl border border-success/40 bg-success/10 p-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="text-xs font-semibold text-success">
                  Your new token “{@new_token.name}”
                </p>
                <code class="mt-2 block select-all break-all rounded-lg bg-base-100 px-3 py-2 font-mono text-xs">
                  {@new_token.token}
                </code>
                <p class="mt-2 text-[11px] text-base-content/70">
                  Shown once. It is stored hashed and cannot be retrieved again — copy it now.
                </p>
              </div>
              <button
                type="button"
                phx-click="dismiss_token"
                class="btn btn-ghost btn-xs min-h-11 sm:min-h-0"
              >
                Dismiss
              </button>
            </div>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">Your API tokens</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              A token is your own secret: anything that presents it acts as you. Nobody else —
              no administrator either — can create one for you or read it.
            </p>

            <form
              id="new-token-form"
              phx-submit="create_token"
              class="mt-3 flex items-end gap-2"
            >
              <label class="min-w-0 flex-1">
                <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
                  Name it after what will use it
                </span>
                <input
                  type="text"
                  name="name"
                  placeholder="e.g. my-laptop-cli"
                  required
                  class="input input-sm mt-1 min-h-11 w-full rounded-lg sm:min-h-0"
                />
              </label>
              <button type="submit" class="btn btn-primary btn-sm min-h-11 sm:min-h-0">
                Create token
              </button>
            </form>

            <ul :if={@tokens != []} id="token-list" class="mt-4 space-y-2">
              <li
                :for={token <- @tokens}
                class="flex flex-wrap items-center gap-2 rounded-lg border border-base-300/70 bg-base-200/40 px-3 py-2"
              >
                <div class="min-w-0 flex-1">
                  <p class="truncate text-xs font-medium">{token.name}</p>
                  <p class="text-[11px] text-base-content/70">
                    <code class="font-mono">{token.token_prefix}…</code>
                    · created {Time.ago(token.inserted_at)} · {if token.last_used_at,
                      do: "used #{Time.ago(token.last_used_at)}",
                      else: "never used"}
                  </p>
                </div>
                <form phx-submit="revoke_token" id={"revoke-token-form-#{token.id}"}>
                  <input type="hidden" name="token_id" value={token.id} />
                  <button
                    type="submit"
                    id={"revoke-token-#{token.id}"}
                    class="btn btn-ghost btn-xs min-h-11 text-error sm:min-h-0"
                    data-confirm={
                      "Revoke “#{token.name}”? Anything using it stops working immediately."
                    }
                  >
                    Revoke
                  </button>
                </form>
              </li>
            </ul>
            <p :if={@tokens == []} id="no-tokens" class="mt-4 text-[11px] text-base-content/70">
              No tokens yet.
            </p>
          </div>

          <div class="rounded-2xl border border-base-300/70 bg-base-100 p-5">
            <h2 class="text-sm font-semibold">How a token is used</h2>
            <p class="mt-1 text-[11px] text-base-content/70">
              Send it as a bearer token on the JSON API:
            </p>
            <code
              id="token-usage"
              phx-no-curly-interpolation
              class="mt-2 block overflow-x-auto rounded-lg bg-base-200/60 px-3 py-2 font-mono text-[11px]"
            >
              curl -H "Authorization: Bearer YOUR_TOKEN" {@mirror_url || "http://localhost:4000"}/api/v1/pages
            </code>
            <p class="mt-2 text-[11px] text-base-content/70">
              It never works against the reader site itself, so a token in a script cannot
              change anything you could not change here.
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :tab, :string, required: true
  attr :current, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={~p"/profile?#{[{:tab, @tab}]}"}
      id={"tab-#{@tab}"}
      class={[
        "-mb-px flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm transition",
        if(@tab == @current,
          do: "border-primary font-medium text-primary",
          else: "border-transparent text-base-content/70 hover:text-primary"
        )
      ]}
      aria-current={if @tab == @current, do: "page"}
    >
      <.icon name={@icon} class="size-4" /> {@label}
    </.link>
    """
  end

  # Said the way a person would: whole seconds, and singular when it is one.
  defp seconds(ms) do
    case max(div(ms + 999, 1000), 1) do
      1 -> "a second"
      60 -> "a minute"
      count -> "#{count} seconds"
    end
  end
end
