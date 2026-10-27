defmodule ConfluencePhxMirrorWeb.Admin.SpacesLive do
  @moduledoc """
  Which spaces this mirror imports, and which ones it could.

  Two lists decide it, and they add up: the keys the deployment fixes
  (`CM_SPACES`) and the ones added here. What is on offer comes from
  Confluence's own listing, held in memory for a few minutes (`SpaceDirectory`),
  so the screen is not one request per render.

  A mirror that imports *every* space has nothing to add — everything is
  already in — so the page says that instead of offering a list. Narrowing such
  a mirror is a decision about what to stop importing, and it starts with
  `CM_SPACES`, not with a button here.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.{Mirror, Settings, SpaceDirectory}
  alias ConfluencePhxMirror.Sync.SpaceScope
  alias ConfluencePhxMirrorWeb.Admin.{Paging, SettingsRefusal}
  alias ConfluencePhxMirrorWeb.Time

  # A mirror can hold hundreds of spaces, so the list is a page of them with a
  # filter over all of them — never the newest handful and a note.
  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Spaces", q: "", page: 1) |> load()}
  end

  # Which page and which filter are the address, so a colleague can be sent the
  # question instead of the screen it was asked on.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(q: Paging.query(params), page: Paging.page_number(params["page"]))
     |> load()}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/spaces?#{[q: q, page: 1]}")}
  end

  @impl true
  def handle_event("add", params, socket) do
    key = params["key"] || ""

    if SpaceScope.wanted() == :all do
      {:noreply, put_flash(socket, :error, narrowing_refusal())}
    else
      change(socket, SpaceScope.add(key, actor(socket)), added_message(key))
    end
  end

  def handle_event("remove", %{"key" => key}, socket) do
    change(
      socket,
      SpaceScope.remove(key, actor(socket)),
      "#{key} removed — the next run stops importing it."
    )
  end

  # Typing narrows what the site lists; picking one adds it. The list comes from
  # `SpaceDirectory`, so a keystroke costs no request to Confluence.
  def handle_event("suggest", %{"key" => typed}, socket) do
    {:noreply, assign(socket, add_key: typed, space_suggestions: suggestions(typed))}
  end

  def handle_event("pick_space", %{"key" => key}, socket) do
    if SpaceScope.wanted() == :all do
      {:noreply, put_flash(socket, :error, narrowing_refusal())}
    else
      socket
      |> assign(:add_key, "")
      |> push_event("space_key_value", %{value: ""})
      |> change(SpaceScope.add(key, actor(socket)), added_message(key))
    end
  end

  def handle_event("refresh", _params, socket) do
    if socket.assigns.paused? do
      {:noreply, put_flash(socket, :error, suspended_message())}
    else
      case SpaceDirectory.refresh() do
        {:ok, _spaces} ->
          {:noreply, socket |> load() |> put_flash(:info, "Confluence was asked again.")}

        {:error, :paused} ->
          {:noreply, put_flash(socket, :error, suspended_message())}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Confluence did not answer: #{inspect(reason)}")}
      end
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
      page_title="Spaces"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:spaces} />
      </:subnav>

      <.admin_header
        title="Spaces"
        subtitle="What this mirror imports, and what it could import next."
      >
        <:actions>
          <button
            type="button"
            phx-click="refresh"
            id="refresh-spaces"
            class="btn btn-outline btn-sm"
            disabled={@paused?}
            title={if @paused?, do: "Confluence calls are paused — resume in Settings"}
          >
            Check Confluence
          </button>
        </:actions>
      </.admin_header>

      <section class="mt-5 rounded-xl border border-base-300/70 bg-base-100 p-4">
        <h2 class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
          Imported
        </h2>

        <p :if={@wanted == :all} id="every-space" class="mt-2 max-w-2xl text-xs text-base-content/70">
          Every space the site lists. Nothing has narrowed this mirror, so there is nothing to add
          here — narrowing starts with <code class="font-mono">CM_SPACES</code>, and the keys named
          there can be widened on this page or at <code class="font-mono">/admin/settings</code>.
        </p>

        <div :if={@wanted != :all} class="mt-2 space-y-2">
          <ul id="space-whitelist" class="flex flex-wrap gap-1.5">
            <li :for={key <- @fixed} class="badge badge-ghost gap-1.5 font-mono text-xs">
              {key}
              <span class="text-[10px] font-sans uppercase tracking-wide text-base-content/70">
                CM_SPACES
              </span>
            </li>
            <li
              :for={key <- @added}
              id={"whitelist-#{key}"}
              class="badge badge-primary gap-1.5 font-mono text-xs"
            >
              {key}
              <button
                type="button"
                phx-click="remove"
                phx-value-key={key}
                aria-label={"Stop importing #{key}"}
                class="text-[10px] font-sans uppercase tracking-wide hover:underline"
              >
                Remove
              </button>
            </li>
          </ul>
        </div>
      </section>

      <section class="mt-4 rounded-xl border border-base-300/70 bg-base-100 p-4">
        <h2 class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
          Mirrored
        </h2>

        <.list_filter
          id="mirrored-filter"
          query={@q}
          label="Filter the mirrored spaces by name or key"
          placeholder="Name or key"
        />

        <p :if={@mirrored == [] and @q != ""} id="no-mirrored-match" class="mt-2 text-xs">
          No space here matches “{@q}”. The filter covers every mirrored space, not this page.
        </p>

        <p :if={@mirrored == [] and @q == ""} class="mt-2 text-xs text-base-content/70">
          Nothing is mirrored yet — the first sync decides what arrives.
        </p>

        <table :if={@mirrored != []} class="mt-2 w-full text-xs">
          <thead class="text-left text-base-content/70">
            <tr>
              <th class="py-1 pr-3 font-medium">Space</th>
              <th class="py-1 pr-3 font-medium">Key</th>
              <th class="py-1 pr-3 text-right font-medium">Pages</th>
              <th class="py-1 text-right font-medium">Last read</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{key, name, synced_at, pages} <- @mirrored} class="border-t border-base-300/50">
              <td class="py-1.5 pr-3">{name}</td>
              <td class="py-1.5 pr-3 font-mono text-[11px]">{key}</td>
              <td class="py-1.5 pr-3 text-right tabular-nums">{pages}</td>
              <td class="py-1.5 text-right text-base-content/70">{Time.ago(synced_at)}</td>
            </tr>
          </tbody>
        </table>

        <.list_pager
          id="mirrored-pager"
          path="/admin/spaces"
          page={@page}
          total={@mirrored_total}
          per_page={@per_page}
          params={%{"q" => @q}}
        />
      </section>

      <section :if={@wanted != :all} class="mt-4 rounded-xl border border-base-300/70 bg-base-100 p-4">
        <h2 class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
          Add a space
        </h2>

        <p :if={@offers == {:error, :paused}} class="mt-2 text-xs">
          Confluence calls are paused, so there is no list to choose from — the keys below are what
          was added before the pause. <a href={~p"/admin/settings"} class="link">Resume in Settings</a>.
        </p>

        <p :if={@offers == {:error, :unreachable}} class="mt-2 text-xs text-base-content/70">
          Confluence did not answer, so there is no list to choose from. <em>Check Confluence</em>
          tries again.
        </p>

        <p :if={@offers == {:ok, []}} id="nothing-to-add" class="mt-2 text-xs text-base-content/70">
          Every space the site lists is already imported. Personal spaces are never offered.
        </p>

        <form
          :if={match?({:ok, [_ | _]}, @offers)}
          id="add-space"
          phx-submit="add"
          class="mt-3 flex flex-wrap items-end gap-2"
        >
          <label class="block text-xs" for="add-space-key">Space</label>
          <.space_key_input
            id="add-space-key"
            name="key"
            value={@add_key}
            change="suggest"
            class="input input-sm w-56 font-mono"
          />
          <button type="submit" id="add-space-submit" class="btn btn-primary btn-sm">
            Add
          </button>
        </form>

        <div :if={match?({:ok, [_ | _]}, @offers)} class="max-w-md">
          <.space_suggestions
            id="add-space-suggestions"
            suggestions={@space_suggestions}
            label="Spaces to add"
          />
        </div>

        <p :if={match?({:ok, [_ | _]}, @offers)} class="mt-2 max-w-2xl text-xs text-base-content/70">
          A key or a name narrows the site's own listing — every space it has is on offer, and
          personal spaces never are. Adding a key widens the list; the next run imports it, and
          nothing is removed that way.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp change(socket, result, message) do
    case result do
      {:ok, _applied} ->
        {:noreply, socket |> load() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, SettingsRefusal.message(reason))}
    end
  end

  defp load(socket) do
    %{q: q, page: page} = socket.assigns

    assign(socket,
      paused?: Settings.sync_paused?(),
      wanted: SpaceScope.wanted(),
      fixed: SpaceScope.fixed(),
      added: SpaceScope.added(),
      per_page: @per_page,
      mirrored:
        Mirror.spaces_by_last_sync(@per_page,
          query: q,
          offset: Paging.offset(page, @per_page)
        ),
      mirrored_total: Mirror.count_mirrored_spaces(query: q),
      offers: offers(),
      add_key: socket.assigns[:add_key] || "",
      space_suggestions: socket.assigns[:space_suggestions] || []
    )
  end

  # What to type ahead of: the site's own listing, cached, minus whatever is
  # already imported and minus personal spaces. A site that does not answer has
  # nothing to offer, which is the same screen as "nothing left to add".
  defp suggestions(typed) do
    case SpaceDirectory.suggest(typed, excluding: SpaceScope.fixed() ++ SpaceScope.added()) do
      {:ok, spaces} -> spaces
      {:error, _unreachable} -> []
    end
  end

  defp narrowing_refusal do
    "This mirror imports every space, so naming one would narrow it to the keys you name. Set CM_SPACES first."
  end

  defp suspended_message do
    "Confluence calls are paused, so nothing was asked. Resume the sync in Settings."
  end

  # Only what is not already imported is worth offering: a mirror that takes
  # everything has nothing left, and a personal space is never what an operator
  # means to publish.
  defp offers do
    case SpaceDirectory.available() do
      {:ok, spaces} ->
        offered =
          spaces
          |> Enum.reject(&(&1[:type] == "personal" or SpaceScope.import?(&1.key)))
          |> Enum.sort_by(&{&1[:name], &1.key})

        {:ok, offered}

      {:error, :paused} ->
        {:error, :paused}

      {:error, _reason} ->
        {:error, :unreachable}
    end
  end

  defp added_message(key) do
    case SpaceScope.wanted() do
      :all ->
        "#{key} added."

      keys ->
        "#{key} added. The next run imports #{Enum.join(keys, ", ")}; anything else is trashed."
    end
  end

  defp actor(socket), do: {:user, socket.assigns.current_user}
end
