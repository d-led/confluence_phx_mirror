defmodule ConfluencePhxMirrorWeb.HeaderSearchLive do
  @moduledoc """
  The top bar's search box, suggesting pages while the reader types.

  A mirror holds tens of thousands of pages, so a box that does nothing until
  Enter is the slowest way to find one: the reader has to guess a phrase the
  full-text engine likes, wait for a page to load, and guess again. This box
  asks the server — narrowed to what the reader may read — for the first few
  pages whose text matches, and the list under it is what the arrow keys walk.

  Nothing is invented on the client: the suggestions are paths the server has
  just offered, and a click on one is only followed if it is still in that list.

  A form still submits. With no suggestion highlighted — or with scripting off —
  Enter goes to `/search` with the query in the address, which is what the plain
  header box used to do.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror.{Search, URLs}
  alias ConfluencePhxMirrorWeb.LiveUserAuth

  # A suggestion, not a result page: five lines fit under the box before the
  # list becomes something to read instead of something to type over.
  @window 5

  @impl true
  def mount(_params, session, socket) do
    # The box is on every page and most readers never type in it, so the reader
    # is resolved on the first keystroke instead of at mount: a live island keeps
    # its assigns, so the lookup costs one query per page where somebody searched
    # rather than one per page view.
    {:ok,
     assign(socket,
       user_id: session["user_id"],
       scope: nil,
       query: session["q"] || "",
       open?: false,
       hits: [],
       offered: MapSet.new()
     )}
  end

  # One box, one place: the top bar of every page. It takes the room between the
  # brand and the controls and sits on the same bottom line as both (`self-end
  # pb-1`), which is what makes the header read as a single line. Below `md` the
  # field would be a sliver, so the bar shows a search button instead.
  defp container_class, do: "relative ml-1 hidden min-w-0 flex-1 self-end pb-1 md:block"

  @impl true
  def handle_event("suggest", %{"q" => q}, socket) do
    query = q |> to_string() |> String.trim()
    scope = scope(socket)
    hits = if query == "", do: [], else: hits(scope, query)

    {:noreply,
     assign(socket,
       scope: scope,
       query: query,
       open?: query != "",
       hits: hits,
       offered: MapSet.new(hits, & &1.path)
     )}
  end

  # Escape leaves the box as it is and puts the list away; typing brings it back.
  def handle_event("close_suggestions", _params, socket) do
    {:noreply, assign(socket, :open?, false)}
  end

  # Enter with nothing highlighted is the old behaviour, unchanged: the full
  # search page, with the query in the address so it can be shared.
  def handle_event("search_all", %{"q" => q}, socket) do
    query = q |> to_string() |> String.trim()
    {:noreply, push_navigate(socket, to: ~p"/search?#{[q: query]}")}
  end

  def handle_event("open_page", %{"path" => path}, socket) do
    if MapSet.member?(socket.assigns.offered, path) do
      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  defp scope(%{assigns: %{scope: %Scope{}}} = socket), do: socket.assigns.scope

  defp scope(socket) do
    %{"user_id" => socket.assigns.user_id} |> LiveUserAuth.reader() |> Scope.for_user()
  end

  defp hits(scope, query) do
    case Search.structured(%{"q" => query}, limit: @window) do
      {:ok, results, _terms} ->
        scope |> Authorization.readable_results(results) |> Enum.map(&hit/1)

      {:error, _message} ->
        []
    end
  end

  defp hit(result) do
    %{
      path: URLs.page_path(result.space.key, result.page.confluence_id, result.page.slug),
      title: result.page.title,
      key: key_badge(result.space),
      space_name: result.space.name,
      updated_at: result.page.external_updated_at,
      blogpost?: result.page.type == "blogpost"
    }
  end

  # A personal space is keyed by its owner's account id, which tells a reader
  # nothing: its name is the whole identification it needs.
  defp key_badge(space) do
    if Authorization.personal_space?(space), do: nil, else: space.key
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="header-search" phx-hook=".HeaderSearch" class={container_class()}>
      <form
        id="header-search-form"
        action={~p"/search"}
        method="get"
        phx-change="suggest"
        phx-submit="search_all"
      >
        <label class="input input-sm flex flex-1 items-center gap-2 rounded-lg border-base-300 bg-base-200/60">
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0 opacity-50" />
          <input
            id="header-search-input"
            type="search"
            name="q"
            value={@query}
            placeholder="Search pages, decisions, people…"
            aria-label="Search the mirror"
            class="grow bg-transparent outline-none placeholder:text-base-content/70"
            autocomplete="off"
            role="combobox"
            aria-expanded={to_string(@open?)}
            aria-controls="header-search-hits"
            aria-autocomplete="list"
            phx-debounce="150"
          />
        </label>
      </form>

      <div
        :if={@open?}
        id="header-search-hits"
        data-hits
        class="absolute inset-x-0 z-50 mt-1 overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-lg"
      >
        <%!-- The count first, the way Confluence opens its list: how much is
        behind the words before any of it is read. --%>
        <p
          :if={@hits != []}
          id="header-search-count"
          class="flex items-center gap-2 px-3 pb-0.5 pt-2 text-[10px] font-semibold uppercase tracking-[0.12em] text-base-content/60"
        >
          Content
          <span class="badge badge-ghost badge-xs font-normal normal-case tracking-normal">
            {length(@hits)}
          </span>
        </p>

        <ul
          role="listbox"
          aria-label="Search suggestions"
          class="menu menu-sm max-h-80 w-full flex-nowrap overflow-y-auto p-0"
        >
          <li :for={hit <- @hits} role="presentation">
            <%!-- `phx-value-path` is the destination the server offered for this
            line; `open_page` refuses anything else. --%>
            <button
              type="button"
              role="option"
              aria-selected="false"
              data-value={hit.path}
              phx-value-path={hit.path}
              phx-click="open_page"
              class="min-w-0 items-start"
            >
              <.icon
                name={if hit.blogpost?, do: "hero-newspaper", else: "hero-document-text"}
                class="mt-0.5 size-4 shrink-0 opacity-60"
              />
              <%!-- Two lines, as Confluence shows them: the title is what was
              found, the line under it is where it lives and how stale it is —
              the two things that tell one similarly named page from another. --%>
              <span class="min-w-0 flex-1">
                <span class="block truncate">{hit.title}</span>
                <span class="block truncate text-[11px] font-normal text-base-content/60">
                  {hit.space_name} · Updated {ConfluencePhxMirrorWeb.Time.ago(hit.updated_at)}
                </span>
              </span>
              <span :if={hit.key} class="badge badge-ghost badge-xs mt-0.5 shrink-0">
                {hit.key}
              </span>
            </button>
          </li>
          <li :if={@hits == []} role="presentation">
            <button type="button" disabled>No page matches that</button>
          </li>
        </ul>

        <a
          id="header-search-all"
          data-search-all
          href={~p"/search?#{[q: @query]}"}
          class="flex items-center gap-2 border-t border-base-300/60 px-3 py-2 text-xs font-medium text-primary transition hover:bg-base-200/50"
        >
          <.icon name="hero-magnifying-glass" class="size-3.5" /> See all results for “{@query}”
        </a>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".HeaderSearch">
        export default {
          mounted() {
            this.cursor = -1
            // A highlight belongs to the list that was on screen when the key
            // was pressed; a new list arrives 150ms later, so it starts clear.
            this.input().addEventListener("input", () => {
              this.cursor = -1
            })
            this.el.addEventListener("keydown", event => this.key(event))

            this.clickAway = event => {
              if (this.el.contains(event.target)) return
              if (!this.el.querySelector("[data-hits]")) return
              this.pushEvent("close_suggestions", {})
            }
            document.addEventListener("click", this.clickAway)
          },
          destroyed() {
            document.removeEventListener("click", this.clickAway)
          },
          key(event) {
            if (event.key === "Escape") {
              if (!this.el.querySelector("[data-hits]")) return
              event.preventDefault()
              this.pushEvent("close_suggestions", {})
              this.input().focus()
            }
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault()
              this.move(event.key === "ArrowDown" ? 1 : -1)
            }
            // Enter takes the highlighted line when there is one, and submits
            // the form — the full search page — when there is not.
            if (event.key === "Enter" && this.cursor >= 0) {
              event.preventDefault()
              this.walk()[this.cursor].click()
            }
          },
          // Arrow keys walk the suggestions and then the row that leaves for the
          // full search page: with five matches on screen the sixth stop is
          // "see all of them", which is what a reader looking for the tail of a
          // long result list wants.
          move(delta) {
            const count = this.walk().length
            if (count === 0) return
            this.paint((this.cursor + delta + count) % count)
          },
          paint(cursor) {
            this.cursor = cursor
            this.walk().forEach((row, index) => {
              const active = index === cursor
              row.classList.toggle("menu-active", active)
              row.classList.toggle("bg-base-200/70", active)
              // `aria-selected` belongs to an option, not to a link that leaves
              // the list; the link announces itself as current instead.
              if (row.getAttribute("role") === "option") {
                row.setAttribute("aria-selected", active ? "true" : "false")
              } else {
                row.setAttribute("aria-current", active ? "true" : "false")
              }
            })
          },
          walk() {
            return [...this.el.querySelectorAll("[role=option], [data-search-all]")]
          },
          options() {
            return [...this.el.querySelectorAll("[role=option]")]
          },
          input() {
            return this.el.querySelector("#header-search-input")
          }
        }
      </script>
    </div>
    """
  end
end
