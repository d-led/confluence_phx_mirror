defmodule ConfluencePhxMirrorWeb.Layouts do
  @moduledoc """
  The mirror's application shell: a Confluence-like top bar, an optional page
  tree sidebar, a content column, an optional right rail and a footer that
  always shows freshness and provenance.
  """

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.BuildInfo
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirrorWeb.Skins
  alias ConfluencePhxMirrorWeb.Time

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the Phoenix 1.8 request scope"
  attr :spaces, :list, default: []
  attr :last_sync_run, :any, default: nil
  attr :mirror_name, :string, default: "Confluence Mirror"
  attr :mirror_url, :string, default: nil
  attr :mirror_host, :string, default: nil
  attr :mirror_source, :any, default: nil

  attr :mirror_repo, :string,
    default: nil,
    doc: "where this software lives; config `:mirror, :repo` by default"

  attr :space, :any, default: nil
  attr :tree, :map, default: %{nodes: [], truncated?: false}, doc: "the sidebar branch"
  attr :current_page, :any, default: nil
  attr :breadcrumbs, :list, default: []
  attr :sidebar?, :boolean, default: true
  attr :rail?, :boolean, default: false

  attr :wide?, :boolean,
    default: false,
    doc: "let the content take the window's width and drop the prose padding (Swagger UI)"

  attr :search?, :boolean, default: true, doc: "render the header search field"
  attr :search_query, :string, default: ""
  attr :page_title, :string, default: nil

  attr :live, :any,
    required: true,
    doc: "the conn or socket this page is rendered from, where the footer's LiveViews live"

  slot :inner_block, required: true
  slot :rail
  slot :toolbar

  slot :subnav,
    doc: "a left column for screens that carry their own navigation, such as the admin area"

  def app(assigns) do
    assigns =
      assign(assigns,
        current_user: assigns.current_scope && assigns.current_scope.user,
        current_admin?: Scope.admin?(assigns.current_scope),
        mirror_repo: assigns.mirror_repo || mirror_repo()
      )

    ~H"""
    <%!-- `data-print="hide"` is what the print stylesheet in `app.css` drops:
    the page is the article, everything else is the screen's furniture. --%>
    <a
      href="#mirror-content"
      data-print="hide"
      class="sr-only focus:not-sr-only focus:absolute focus:left-3 focus:top-3 focus:z-[60] focus:rounded-lg focus:bg-primary focus:px-3 focus:py-2 focus:text-sm focus:font-medium focus:text-primary-content"
    >
      Skip to content
    </a>

    <div class="flex min-h-screen flex-col bg-base-100 text-base-content">
      <div
        :if={Source.demo?(@mirror_source)}
        data-print="hide"
        class="border-b border-warning/50 bg-warning/15"
      >
        <div class="mx-auto flex w-full max-w-[1600px] items-center gap-2 px-3 py-1.5 text-xs text-base-content/80 sm:px-5">
          <.icon name="hero-beaker" class="size-4 shrink-0 text-warning" />
          <p>
            <span class="font-semibold">Demo data.</span>
            This mirror was filled from a sample snapshot bundled with the application, not from a live Confluence site.
          </p>
        </div>
      </div>

      <header
        data-print="hide"
        class="sticky top-0 z-40 border-b border-base-300/70 bg-base-100/85 backdrop-blur"
      >
        <div class="mx-auto flex w-full max-w-[1600px] items-center gap-2 px-3 py-2 sm:gap-3 sm:px-5">
          <button
            :if={@sidebar? and (@space || @spaces != [])}
            type="button"
            data-sidebar-toggle
            aria-controls="mirror-sidebar"
            aria-expanded="true"
            aria-label="Collapse sidebar"
            title="Collapse sidebar"
            class="group -ml-1 grid size-11 shrink-0 place-items-center rounded-lg text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 lg:size-9"
          >
            <%!--
              The panel glyph Atlassian uses: a sidebar with a divider and a
              chevron pointing the way the panel is about to move — right while
              it is closed, left while it is open. `sidebar.js` keeps
              `aria-expanded` in step and these two variants follow it, so the
              button never states the wrong action.
            --%>
            <svg
              aria-hidden="true"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              class="size-5 group-aria-expanded:hidden"
            >
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <path d="M9 3v18" />
              <path d="m14 9 3 3-3 3" />
            </svg>
            <svg
              aria-hidden="true"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              class="hidden size-5 group-aria-expanded:block"
            >
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <path d="M9 3v18" />
              <path d="m16 15-3-3 3-3" />
            </svg>
          </button>
          <.link
            navigate={~p"/"}
            class="group flex items-center gap-2.5 rounded-lg px-1 py-1 transition hover:bg-base-200/70"
          >
            <span class="grid size-8 place-items-center rounded-lg bg-primary font-bold text-primary-content shadow-sm transition group-hover:scale-105">
              {brand_initial(@mirror_name)}
            </span>
            <span class="hidden flex-col leading-tight sm:flex">
              <span class="text-sm font-semibold">{@mirror_name}</span>
              <span class="text-[11px] uppercase tracking-wide text-base-content/70">
                mirror of {@mirror_host || "the demo snapshot"}
              </span>
            </span>
          </.link>

          <%!-- The field's bottom sits on the brand's last line, which is what
          makes the header read as one line: bottom-aligned with the brand,
          less the brand link's own bottom padding (`pb-1` here). The island
          keeps that shape and adds what matches to it as the reader types. --%>
          <Layouts.header_search :if={@search?} live={@live} query={@search_query} />

          <%!-- The whole row sits on one bottom line: the brand's last line, the
          search field and these controls all end where that line ends (`pb-1` is
          the brand link's own bottom padding). --%>
          <div class="ml-auto flex items-center gap-1 self-end pb-1">
            <.link
              :if={@search?}
              navigate={~p"/search"}
              class="btn btn-ghost btn-sm md:hidden"
              aria-label="Search"
            >
              <.icon name="hero-magnifying-glass" class="size-4" />
            </.link>

            <%!-- One `name` for every top-bar menu: opening one closes the other,
            which is the native accordion behaviour of <details>. `.TopbarMenu`
            adds what <details> leaves out — a click elsewhere and Escape close
            it — and keeps the reader's own `open` across a re-render, which a
            streaming page performs every second. The space switcher is the
            exception: it is a LiveView that keeps its state on the server. --%>
            {space_switcher(@live)}

            <.theme_menu />

            <%= if @current_user do %>
              <details
                id="account-menu"
                name="topbar-menu"
                phx-hook=".TopbarMenu"
                class="dropdown dropdown-end"
              >
                <summary class="btn btn-ghost btn-sm gap-1.5" aria-label="Account">
                  <span class="grid size-6 place-items-center rounded-full bg-secondary text-[11px] font-semibold text-secondary-content">
                    {initials(@current_user.display_name || @current_user.email)}
                  </span>
                </summary>
                <ul class="menu dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
                  <li class="menu-title truncate">{@current_user.email}</li>
                  <li>
                    <span class="text-xs uppercase tracking-wide text-base-content/70">{@current_user.role}</span>
                  </li>
                  <li>
                    <.link navigate={~p"/profile"} id="account-profile-link">
                      <.icon name="hero-user" class="size-4" /> Your account
                    </.link>
                  </li>
                  <li>
                    <.link navigate={~p"/profile?tab=tokens"} id="account-tokens-link">
                      <.icon name="hero-key" class="size-4" /> API tokens
                    </.link>
                  </li>
                  <li :if={@current_admin?}>
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
        <div
          :if={@sidebar? and (@space || @spaces != [])}
          data-sidebar-backdrop
          hidden
          aria-hidden="true"
          class="fixed inset-0 z-40 bg-base-content/40 backdrop-blur-sm lg:hidden"
        >
        </div>

        <aside
          :if={@sidebar? and (@space || @spaces != [])}
          id="mirror-sidebar"
          tabindex="-1"
          data-print="hide"
          aria-label={if @space, do: "Pages in #{@space.name}", else: "Mirrored spaces"}
          class="fixed inset-y-0 left-0 z-50 w-72 max-w-[85vw] -translate-x-full overflow-y-auto overscroll-contain border-r border-base-300/60 bg-base-100 shadow-lg transition-transform duration-200 focus:outline-none motion-reduce:transition-none data-[open]:translate-x-0 lg:static lg:z-auto lg:w-72 lg:max-w-none lg:translate-x-0 lg:bg-base-200/25 lg:shadow-none lg:data-[collapsed]:hidden"
        >
          <div class="p-4 lg:sticky lg:top-[57px] lg:max-h-[calc(100vh-57px)] lg:overflow-y-auto">
            <%= if @space do %>
              <div class="mb-3 flex items-center gap-2">
                <.link
                  navigate={~p"/spaces/#{@space.key}"}
                  class="min-w-0 flex-1 truncate text-xs font-semibold uppercase tracking-wider text-base-content/70 hover:text-primary"
                >
                  {@space.name}
                </.link>
                <.space_key :if={named?(@space)} key={@space.key} />
              </div>
              <.page_tree nodes={@tree.nodes} space_key={@space.key} current={@current_page} />
              <p :if={@tree.truncated?} class="mt-2 px-2 text-[11px] text-base-content/70">
                Some pages are not shown here.
                <.link
                  navigate={ConfluencePhxMirror.Mirror.URLs.space_pages_path(@space.key)}
                  class="font-medium text-primary hover:underline"
                >
                  Browse all of {@space.key}
                </.link>
              </p>
            <% else %>
              <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/70">
                Spaces
              </p>
              <ul class="menu menu-sm gap-1 p-0">
                <li :for={space <- @spaces}>
                  <.space_link space={space} />
                </li>
              </ul>
            <% end %>
          </div>
        </aside>

        <main id="mirror-content" tabindex="-1" class="min-w-0 flex-1 focus:outline-none">
          {render_slot(@toolbar)}
          <%!-- Left, not centred: collapsing the tree is how a reader asks for
          more room, and a column that stays centred only widens in both
          directions. Prose keeps a measure of its own in `app.css`; tables,
          lists and the page's own furniture take the width. --%>
          <div class={[
            "w-full px-4 sm:px-8",
            @wide? && "py-2",
            !@wide? && "max-w-[88rem] py-3 sm:py-5 lg:py-6"
          ]}>
            <%= if @subnav != [] do %>
              <%!-- A screen that brings its own navigation gets a column for it
              instead of a strip above the content. The column is sticky so the
              list stays reachable down a long page. --%>
              <div class="lg:flex lg:items-start lg:gap-8">
                <div class="mb-5 lg:sticky lg:top-[4.5rem] lg:mb-0 lg:w-60 lg:shrink-0">
                  {render_slot(@subnav)}
                </div>
                <div class="min-w-0 flex-1">
                  {render_slot(@inner_block)}
                </div>
              </div>
            <% else %>
              {render_slot(@inner_block)}
            <% end %>
          </div>
        </main>

        <aside
          :if={@rail?}
          data-print="hide"
          class="hidden w-80 shrink-0 border-l border-base-300/60 xl:block"
        >
          <div class="sticky top-[57px] max-h-[calc(100vh-57px)] space-y-5 overflow-y-auto p-5">
            {render_slot(@rail)}
          </div>
        </aside>
      </div>

      <footer data-print="hide" class="mt-auto border-t border-base-300/70 bg-base-200/30">
        <div class="mx-auto flex w-full max-w-[1600px] flex-col gap-2 px-4 py-5 text-xs text-base-content/70 sm:flex-row sm:items-center sm:justify-between sm:px-6">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span class="font-medium text-base-content/80">{@mirror_name}</span>
            <span aria-hidden="true">·</span>
            <%!--
              Flex, not inline text plus an inline icon: an icon with a baseline
              taller than the text drags the words beside it out of line with
              the rest of the row.
            --%>
            <span :if={@mirror_url} class="inline-flex items-center gap-1">
              <span>Original:</span>
              <a
                href={@mirror_url}
                class="inline-flex items-center gap-0.5 font-medium text-primary hover:underline"
                target="_blank"
                rel="noopener noreferrer"
              >
                {@mirror_host}<.icon name="hero-arrow-top-right-on-square" class="size-3" />
              </a>
            </span>
            <span :if={is_nil(@mirror_url)}>Source: {source_label(@mirror_source)}</span>
            <span aria-hidden="true">·</span>
            <span :if={@last_sync_run}>
              Last sync {Time.ago(@last_sync_run.finished_at || @last_sync_run.started_at)}
            </span>
            <span :if={is_nil(@last_sync_run)} class="text-warning">Never synced</span>
            <%!-- A reader who notices that a page is old deserves the reason in the
            same line as the age: the mirror is not broken, it is paused. --%>
            <span :if={paused?()} id="mirror-paused" class="text-warning">
              · updates paused
            </span>
          </div>
          <div class="flex flex-wrap items-center gap-x-4 gap-y-1">
            <a
              :if={@mirror_repo}
              href={@mirror_repo}
              aria-label="Source code on GitHub"
              class="inline-flex items-center gap-1 hover:text-primary"
              target="_blank"
              rel="noopener noreferrer"
            >
              <%!-- The GitHub mark, which heroicons (having no brand icons) leaves to us. --%>
              <svg aria-hidden="true" viewBox="0 0 16 16" fill="currentColor" class="size-3.5">
                <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
              </svg>
              <span>Source</span>
            </a>
            <a href={~p"/about"} class="hover:text-primary">About</a>
            <a
              :if={ConfluencePhxMirrorWeb.Api.OpenApi.enabled?()}
              href={~p"/api/docs"}
              class="hover:text-primary"
            >
              API docs
            </a>
            <a href={~p"/health"} class="hover:text-primary">Health</a>
            <%!--
              The count is its own LiveView, rendered into this page: a
              controller-rendered page has no process for Presence to track,
              so the widget brings one.
            --%>
            {site_presence(@live)}
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-lock-closed" class="size-3" /> Read-only
            </span>
            <%!--
              Only an administrator has a use for which build this is; readers
              get the freshness above instead.
            --%>
            <span
              :if={@current_admin?}
              id="build-info"
              class="inline-flex items-center gap-1"
              title={BuildInfo.description()}
            >
              <.icon name="hero-code-bracket" class="size-3" />
              <span class="font-mono">{BuildInfo.label()}</span>
              <a
                :if={ci_run_url()}
                href={ci_run_url()}
                class="font-mono text-primary hover:underline"
                target="_blank"
                rel="noopener noreferrer"
              >
                {BuildInfo.ci_label()}
              </a>
            </span>
          </div>
        </div>
      </footer>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  # A LiveView rendered from a conn makes its own DOM id; one rendered inside
  # another LiveView is a child and has to be told which it is.
  defp site_presence(%Phoenix.LiveView.Socket{} = socket),
    do: live_render(socket, ConfluencePhxMirrorWeb.SitePresenceLive, id: "site-presence")

  defp site_presence(conn), do: live_render(conn, ConfluencePhxMirrorWeb.SitePresenceLive)

  # The same two flavours for the space switcher, which is a LiveView because
  # "what matches" is the server's question: a mirror with thousands of spaces
  # cannot ship its directory in a menu.
  defp space_switcher(%Phoenix.LiveView.Socket{} = socket) do
    live_render(socket, ConfluencePhxMirrorWeb.SpaceSwitcherLive, id: "space-switcher-live")
  end

  defp space_switcher(conn), do: live_render(conn, ConfluencePhxMirrorWeb.SpaceSwitcherLive)

  # The header's search box is an island for the same reason: "what matches" is
  # the server's question, and a pageful of suggestions belongs to the reader's
  # permissions. The query travels in the session so the box opens on the words
  # the page it sits on is already showing.
  attr :live, :any, required: true, doc: "a conn or a LiveView socket"
  attr :query, :string, default: ""

  def header_search(%{live: %Phoenix.LiveView.Socket{} = socket} = assigns) do
    assigns =
      assign(
        assigns,
        :island,
        live_render(socket, ConfluencePhxMirrorWeb.HeaderSearchLive,
          id: "header-search-live",
          session: island_session(assigns)
        )
      )

    ~H"{@island}"
  end

  def header_search(%{live: conn} = assigns) do
    assigns =
      assign(
        assigns,
        :island,
        live_render(conn, ConfluencePhxMirrorWeb.HeaderSearchLive,
          session: island_session(assigns)
        )
      )

    ~H"{@island}"
  end

  defp island_session(assigns), do: %{"q" => assigns.query}

  defp source_label(nil), do: "not configured"

  defp source_label(module) do
    case Source.kind(module) do
      :demo -> "bundled demo snapshot (not a Confluence site)"
      :live -> "Confluence REST API"
    end
  end

  # The footer says the mirror is paused next to how old it is, because those
  # two facts are one question to a reader: "is this page current?".
  defp paused?, do: Settings.sync_paused?()

  # Where this software lives, for the footer's source link. A fork that does
  # not want the upstream link drops the config key.
  defp mirror_repo do
    :confluence_phx_mirror
    |> Application.get_env(:mirror, [])
    |> Keyword.get(:repo)
  end

  # The run that built this release, when a pipeline did. A footer link to a
  # build nobody can look at would be noise, so the label and the link come from
  # the same value.
  defp ci_run_url do
    case BuildInfo.ci() do
      %{run_url: url} when is_binary(url) -> url
      _no_ci -> nil
    end
  end

  defp brand_initial(name) do
    name
    |> String.first()
    |> String.upcase()
  end

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

  @doc """
  The reader's variant picker: system, light or dark.

  The theme itself is the administrator's choice, so there is nothing else to
  choose here — every reader wears the same brand in the variant they prefer.

  Its `<details>` shares the `topbar-menu` name with the other top-bar menus,
  so opening one closes the others.
  """
  def theme_menu(assigns) do
    ~H"""
    <details
      id="theme-menu"
      name="topbar-menu"
      phx-hook=".TopbarMenu"
      class="dropdown dropdown-end"
    >
      <summary class="btn btn-ghost btn-sm" aria-label="Theme">
        <.icon name="hero-swatch" class="size-4" />
      </summary>
      <ul class="menu dropdown-content z-50 mt-2 w-40 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
        <li :for={variant <- Skins.variants()}>
          <a href={~p"/theme/#{variant.name}"}>
            <.icon name={variant.icon} class="size-4" /> {variant.label}
          </a>
        </li>
      </ul>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TopbarMenu">
        export default {
          mounted() {
            // `open` is the reader's state, not the server's: LiveView keeps the
            // attributes it renders, and a streaming page patches its own DOM
            // every second — which is how a menu used to shut in the reader's
            // face. Remember what they chose and put it back after a patch.
            //
            // Closing it — a click elsewhere, Escape — is `topbar_menus.js`: the
            // layout is also rendered by controllers, and a hook in a page no
            // LiveView owns never runs.
            this.wasOpen = this.el.open
            this.el.addEventListener("toggle", () => {
              this.wasOpen = this.el.open
            })
          },
          updated() {
            if (this.el.open !== this.wasOpen) this.el.open = this.wasOpen
          }
        }
      </script>
    </details>
    """
  end

  attr :space, :map, required: true, doc: "a space, with at least its name and key"

  # A space in a list: its name, because that is what a reader looks for, and
  # its key, because that is what tells LOAD01 Test Space 1 apart from LOAD01
  # Test Space 2. The key is a small column of its own rather than a badge
  # hugging the name: badges do not shrink, and one wide key pushed every row of
  # the switcher out of the menu.
  defp space_link(assigns) do
    ~H"""
    <.link navigate={~p"/spaces/#{@space.key}"} class="flex items-center gap-2">
      <span class="min-w-0 flex-1 truncate">{@space.name}</span>
      <.space_key :if={named?(@space)} key={@space.key} />
    </.link>
    """
  end

  attr :key, :string, required: true

  defp space_key(assigns) do
    ~H"""
    <span class={["w-16 shrink-0 truncate text-right", key_text()]}>{@key}</span>
    """
  end

  # A personal space is named after its owner and keyed by an account id
  # (`~5F057CBE0B38B10022628D68`): the name is the whole story, and the key is a
  # truncated id that names nothing.
  defp named?(%{type: "personal"}), do: false
  defp named?(_space), do: true

  # A key is an identifier, not prose: monospaced, small, and quiet enough that
  # it never competes with the name it belongs to.
  defp key_text, do: "font-mono text-[10px] font-normal text-base-content/60"
end
