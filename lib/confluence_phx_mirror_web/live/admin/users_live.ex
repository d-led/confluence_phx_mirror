defmodule ConfluencePhxMirrorWeb.Admin.UsersLive do
  @moduledoc "Reader accounts and API tokens."

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       new_token: nil,
       form: to_form(%{"email" => "", "role" => "member"}, as: :user)
     )
     |> load()}
  end

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    case Accounts.create_user(
           %{"email" => params["email"], "role" => params["role"]},
           actor(socket)
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created #{user.email}.")
         |> assign(form: to_form(%{"email" => "", "role" => "member"}, as: :user))
         |> load()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form:
             to_form(%{"email" => params["email"], "role" => params["role"]}, as: :user)
             |> Map.put(:errors, changeset_errors(changeset))
         )}
    end
  end

  def handle_event("change_role", %{"user_id" => user_id, "role" => role}, socket) do
    user = Accounts.get_user(String.to_integer(user_id))

    case Accounts.change_role(user, role, actor(socket)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Role updated.") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not update the role.")}
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
      |> Enum.map(fn user -> %{user: user, tokens: Accounts.list_api_tokens(user)} end)

    assign(socket, users: users)
  end

  defp changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, _opts}} ->
      {field, {message, []}}
    end)
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
      page_title="Users"
      sidebar?={false}
    >
      <header class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300/70 pb-5">
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">
            Administration
          </p>
          <h1 class="mt-1 text-3xl font-semibold">Users &amp; API tokens</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Mirror-local accounts only — no Confluence credentials are stored.
          </p>
        </div>
        <a href={~p"/admin"} class="btn btn-ghost btn-sm">← Dashboard</a>
      </header>

      <div :if={@new_token} class="mt-5 rounded-xl border border-success/40 bg-success/10 p-4">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="text-xs font-semibold text-success">New API token for {@new_token.user}</p>
            <code class="mt-2 block select-all break-all rounded-lg bg-base-100 px-3 py-2 font-mono text-xs">
              {@new_token.token}
            </code>
            <p class="mt-2 text-[11px] text-base-content/55">
              Send it as <code>Authorization: Bearer …</code>. It is stored hashed and cannot be shown again.
            </p>
          </div>
          <button type="button" phx-click="dismiss_token" class="btn btn-ghost btn-xs">Dismiss</button>
        </div>
      </div>

      <.form
        for={@form}
        id="create-user-form"
        phx-submit="create_user"
        class="mt-6 flex flex-col gap-3 rounded-xl border border-base-300/70 bg-base-100 p-4 sm:flex-row sm:items-end"
      >
        <div class="flex-1">
          <.input
            field={@form[:email]}
            type="email"
            label="E-mail"
            placeholder="reader@example.com"
            required
          />
        </div>
        <div class="w-full sm:w-40">
          <.input
            field={@form[:role]}
            type="select"
            label="Role"
            options={[{"Member", "member"}, {"Admin", "admin"}]}
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Create user</button>
      </.form>

      <section class="mt-6 overflow-hidden rounded-xl border border-base-300/70 bg-base-100">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>User</th>
              <th>Role</th>
              <th>Tokens</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={%{user: user, tokens: tokens} <- @users} class="align-top">
              <td>
                <p class="font-medium">{user.email}</p>
                <p class="text-[11px] text-base-content/45">
                  {if user.last_sign_in_at,
                    do: "last seen #{ConfluencePhxMirrorWeb.Time.ago(user.last_sign_in_at)}",
                    else: "never signed in"}
                </p>
              </td>
              <td>
                <form phx-submit="change_role" class="flex items-center gap-1">
                  <input type="hidden" name="user_id" value={user.id} />
                  <select name="role" class="select select-xs select-bordered">
                    <option value="member" selected={user.role == "member"}>member</option>
                    <option value="admin" selected={user.role == "admin"}>admin</option>
                  </select>
                  <button type="submit" class="btn btn-ghost btn-xs">save</button>
                </form>
              </td>
              <td class="min-w-[16rem]">
                <ul class="space-y-1">
                  <li :for={token <- tokens} class="flex items-center gap-2 text-[11px]">
                    <code class="badge badge-ghost badge-xs font-mono">{token.token_prefix}…</code>
                    <span class="truncate text-base-content/60">{token.name}</span>
                    <span :if={token.last_used_at} class="text-base-content/35">used {ConfluencePhxMirrorWeb.Time.ago(
                      token.last_used_at
                    )}</span>
                    <form phx-submit="revoke_token" class="ml-auto">
                      <input type="hidden" name="user_id" value={user.id} />
                      <input type="hidden" name="token_id" value={token.id} />
                      <button type="submit" class="btn btn-ghost btn-xs text-error">revoke</button>
                    </form>
                  </li>
                  <li :if={tokens == []} class="text-[11px] text-base-content/40">No tokens.</li>
                </ul>
              </td>
              <td>
                <form
                  id={"new-token-#{user.id}"}
                  phx-submit="create_token"
                  class="flex items-center justify-end gap-1"
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <input
                    type="text"
                    name="name"
                    placeholder="token name"
                    class="input input-xs w-28"
                    required
                  />
                  <button type="submit" class="btn btn-outline btn-xs">new token</button>
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
