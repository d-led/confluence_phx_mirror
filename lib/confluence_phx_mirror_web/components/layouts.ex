defmodule ConfluencePhxMirrorWeb.Layouts do
  @moduledoc """
  The mirror's application shell: a Confluence-like top bar, an optional page
  tree sidebar, a content column, an optional right rail and a footer that
  always shows freshness and provenance.
  """

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirrorWeb.Skins
  alias ConfluencePhxMirrorWeb.Time

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the Phoenix 1.8 request scope"
  attr :spaces, :list, default: []
  attr :last_sync_run, :any, default: nil
  attr :mirror_name, :string, default: "Confluence Mirror"
  attr :mirror_source, :any, default: nil
  attr :space, :any, default: nil
  attr :tree, :list, default: []
  attr :current_page, :any, default: nil
  attr :breadcrumbs, :list, default: []
  attr :sidebar?, :boolean, default: true
  attr :rail?, :boolean, default: false
  attr :search_query, :string, default: ""
  attr :page_title, :string, default: nil

  slot :inner_block, required: true
  slot :rail
  slot :toolbar

  def app(assigns) do
    assigns = assign(assigns, :current_user, assigns.current_scope && assigns.current_scope.user)

    ~H"""
    <div class="flex min-h-screen flex-col bg-base-100 text-base-content">
      <header class="sticky top-0 z-40 border-b border-base-300/70 bg-base-100/85 backdrop-blur">
        <div class="mx-auto flex w-full max-w-[1600px] items-center gap-3 px-3 py-2 sm:px-5">
          <.link
            navigate={~p"/"}
            class="group flex items-center gap-2.5 rounded-lg px-1 py-1 transition hover:bg-base-200/70"
          >
            <span class="grid size-8 place-items-center rounded-lg bg-primary font-bold text-primary-content shadow-sm transition group-hover:scale-105">
              C
            </span>
            <span class="hidden flex-col leading-tight sm:flex">
              <span class="text-sm font-semibold">{@mirror_name}</span>
              <span class="text-[11px] uppercase tracking-wide text-base-content/50">read-only mirror</span>
            </span>
          </.link>

          <form action={~p"/search"} method="get" class="ml-1 hidden min-w-0 flex-1 md:block">
            <label class="input input-sm flex w-full items-center gap-2 rounded-lg border-base-300 bg-base-200/60">
              <.icon name="hero-magnifying-glass" class="size-4 shrink-0 opacity-50" />
              <input
                type="search"
                name="q"
                value={@search_query}
                placeholder="Search pages, decisions, people…"
                class="grow bg-transparent outline-none placeholder:text-base-content/40"
                autocomplete="off"
              />
            </label>
          </form>

          <div class="ml-auto flex items-center gap-1">
            <.link navigate={~p"/search"} class="btn btn-ghost btn-sm md:hidden" aria-label="Search">
              <.icon name="hero-magnifying-glass" class="size-4" />
            </.link>

            <details class="dropdown dropdown-end hidden sm:block">
              <summary class="btn btn-ghost btn-sm gap-1.5">
                <.icon name="hero-rectangle-stack" class="size-4" />
                <span class="hidden lg:inline">Spaces</span>
              </summary>
              <ul class="menu dropdown-content z-50 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl">
                <li :for={space <- @spaces}>
                  <.link
                    navigate={~p"/spaces/#{space.key}"}
                    class="flex items-center justify-between gap-2"
                  >
                    <span class="truncate">{space.name}</span>
                    <span class="badge badge-ghost badge-xs">{space.key}</span>
                  </.link>
                </li>
                <li :if={@spaces == []} class="menu-disabled"><span>No spaces mirrored yet</span></li>
                <li class="menu-title text-[10px] uppercase tracking-wider">Browse</li>
                <li>
                  <.link navigate={~p"/spaces"} class="gap-2">
                    <.icon name="hero-rectangle-stack" class="size-4" /> All spaces
                  </.link>
                </li>
                <li>
                  <.link navigate={~p"/labels"} class="gap-2">
                    <.icon name="hero-tag" class="size-4" /> Labels
                  </.link>
                </li>
                <li>
                  <.link navigate={~p"/people"} class="gap-2">
                    <.icon name="hero-users" class="size-4" /> People
                  </.link>
                </li>
                <li>
                  <.link navigate={~p"/recent"} class="gap-2">
                    <.icon name="hero-clock" class="size-4" /> Recently updated
                  </.link>
                </li>
              </ul>
            </details>

            <.theme_menu />

            <%= if @current_user do %>
              <details class="dropdown dropdown-end">
                <summary class="btn btn-ghost btn-sm gap-1.5" aria-label="Account">
                  <span class="grid size-6 place-items-center rounded-full bg-secondary text-[11px] font-semibold text-secondary-content">
                    {initials(@current_user)}
                  </span>
                </summary>
                <ul class="menu dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl">
                  <li class="menu-title truncate">{@current_user.email}</li>
                  <li>
                    <span class="text-xs uppercase tracking-wide text-base-content/50">{@current_user.role}</span>
                  </li>
                  <li :if={@current_user.role == "admin"}>
                    <.link navigate={~p"/admin"}><.icon name="hero-cog-6-tooth" class="size-4" />
                    Admin</.link>
                  </li>
                  <li>
                    <form action={~p"/session"} method="post">
                      <input type="hidden" name="_method" value="delete" />
                      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                      <button type="submit" class="w-full text-left">
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Sign out
                      </button>
                    </form>
                  </li>
                </ul>
              </details>
            <% else %>
              <.link navigate={~p"/session"} class="btn btn-primary btn-sm">Sign in</.link>
            <% end %>
          </div>
        </div>

        <%= if @breadcrumbs != [] do %>
          <div class="mx-auto flex w-full max-w-[1600px] items-center gap-2 px-3 pb-2 sm:px-5">
            <.breadcrumbs items={@breadcrumbs} current={@page_title} />
          </div>
        <% end %>
      </header>

      <div class="mx-auto flex w-full max-w-[1600px] flex-1 items-stretch">
        <aside
          :if={@sidebar? and (@space || @spaces != [])}
          class="hidden w-72 shrink-0 border-r border-base-300/60 bg-base-200/25 lg:block"
        >
          <div class="sticky top-[57px] max-h-[calc(100vh-57px)] overflow-y-auto p-4">
            <%= if @space do %>
              <div class="mb-3 flex items-center justify-between gap-2">
                <.link
                  navigate={~p"/spaces/#{@space.key}"}
                  class="truncate text-xs font-semibold uppercase tracking-wider text-base-content/50 hover:text-primary"
                >
                  {@space.name}
                </.link>
                <span class="badge badge-ghost badge-xs">{@space.key}</span>
              </div>
              <.page_tree nodes={@tree} space_key={@space.key} current={@current_page} />
            <% else %>
              <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Spaces
              </p>
              <ul class="menu menu-sm gap-1 p-0">
                <li :for={space <- @spaces}>
                  <.link navigate={~p"/spaces/#{space.key}"} class="flex items-center justify-between">
                    <span class="truncate">{space.name}</span>
                    <span class="badge badge-ghost badge-xs">{space.key}</span>
                  </.link>
                </li>
              </ul>
            <% end %>
          </div>
        </aside>

        <main class="min-w-0 flex-1">
          {render_slot(@toolbar)}
          <div class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-8 lg:py-10">
            {render_slot(@inner_block)}
          </div>
        </main>

        <aside :if={@rail?} class="hidden w-80 shrink-0 border-l border-base-300/60 xl:block">
          <div class="sticky top-[57px] max-h-[calc(100vh-57px)] space-y-5 overflow-y-auto p-5">
            {render_slot(@rail)}
          </div>
        </aside>
      </div>

      <footer class="mt-auto border-t border-base-300/70 bg-base-200/30">
        <div class="mx-auto flex w-full max-w-[1600px] flex-col gap-2 px-4 py-5 text-xs text-base-content/60 sm:flex-row sm:items-center sm:justify-between sm:px-6">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span class="font-medium text-base-content/80">{@mirror_name}</span>
            <span aria-hidden="true">·</span>
            <span>Source: {source_label(@mirror_source)}</span>
            <span aria-hidden="true">·</span>
            <span :if={@last_sync_run}>
              Last sync {Time.ago(@last_sync_run.finished_at || @last_sync_run.started_at)}
            </span>
            <span :if={is_nil(@last_sync_run)} class="text-warning">Never synced</span>
          </div>
          <div class="flex flex-wrap items-center gap-x-4 gap-y-1">
            <a href={~p"/about"} class="hover:text-primary">About</a>
            <a href={~p"/api/v1/stats"} class="hover:text-primary">API</a>
            <a href={~p"/health"} class="hover:text-primary">Health</a>
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-lock-closed" class="size-3" /> Read-only
            </span>
          </div>
        </div>
      </footer>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp initials(%{display_name: name, email: email}) do
    source = name || email

    source
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  defp source_label(nil), do: "not configured"
  defp source_label(ConfluencePhxMirror.Confluence.DemoSource), do: "bundled demo snapshot"
  defp source_label(ConfluencePhxMirror.Confluence.HttpSource), do: "Confluence REST API"
  defp source_label(module), do: inspect(module)

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc "Theme picker; built-in and site-declared skins from `ConfluencePhxMirrorWeb.Skins`."
  def theme_menu(assigns) do
    ~H"""
    <details class="dropdown dropdown-end">
      <summary class="btn btn-ghost btn-sm" aria-label="Theme">
        <.icon name="hero-swatch" class="size-4" />
      </summary>
      <ul class="menu dropdown-content z-50 mt-2 w-44 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl">
        <li :for={skin <- Skins.all()}>
          <a href={~p"/theme/#{skin.name}"}>
            <.icon name={skin.icon} class="size-4" /> {skin.label}
          </a>
        </li>
      </ul>
    </details>
    """
  end
end
