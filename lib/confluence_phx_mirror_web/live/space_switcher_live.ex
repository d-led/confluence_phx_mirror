defmodule ConfluencePhxMirrorWeb.SpaceSwitcherLive do
  @moduledoc """
  The top bar's space switcher: a few letters, arrow keys, Enter.

  A mirror can hold hundreds or thousands of spaces, so the menu cannot be a
  list of them: it is the same widget the admin dashboard offers for "sync one
  space" — a find box whose list the server narrows, with the browser only
  moving the highlight.

  Open and closed are assigns rather than the `open` attribute of a `<details>`,
  because a page whose content streams (the sync log writes a line a second)
  re-renders, and LiveView keeps the browser's attributes equal to what the
  server rendered: an `open` the reader put there is taken away again and the
  menu shuts in their face. An assign survives its parent's renders.

  Every page renders this with `live_render/3`, from a conn on the pages the
  router never mounted and from a socket inside the LiveView pages, so the
  switcher behaves the same in both. The reader is resolved from the session,
  as the presence widgets do: a LiveView rendered into a page does not pass
  through the router's `on_mount` hooks.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.UIComponents, only: [searchable_select: 1]

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirrorWeb.LiveUserAuth

  # A menu, not a directory: `/spaces` is where the whole list lives.
  @window 20

  @impl true
  def mount(_params, session, socket) do
    scope = session |> LiveUserAuth.reader() |> Scope.for_user()
    spaces = Authorization.readable_spaces(scope, limit: @window)

    {:ok,
     assign(socket,
       scope: scope,
       open?: false,
       query: "",
       spaces: spaces,
       options: options(spaces)
     )}
  end

  @impl true
  def handle_event("toggle_switcher", _params, socket) do
    {:noreply, assign(socket, :open?, not socket.assigns.open?)}
  end

  def handle_event("close_switcher", _params, socket) do
    {:noreply, assign(socket, :open?, false)}
  end

  def handle_event("search", %{"q" => query}, socket) do
    query = String.trim(query || "")
    spaces = Authorization.readable_spaces(socket.assigns.scope, limit: @window, query: query)

    {:noreply, assign(socket, query: query, spaces: spaces, options: options(spaces))}
  end

  # Enter with nothing highlighted asks for the space the reader typed, so the
  # answer comes from the query itself and not from a list a debounce may not
  # have refreshed yet.
  def handle_event("open_first", %{"q" => query}, socket) do
    query = String.trim(query || "")

    case first_match(socket.assigns.scope, query) do
      {:ok, space} -> {:noreply, push_navigate(socket, to: ~p"/spaces/#{space.key}")}
      :none -> {:noreply, assign(socket, query: query, spaces: [], options: [])}
    end
  end

  # Taking a line is a click on it, whether the reader used a mouse or Enter.
  def handle_event("open_space", %{"key" => key}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/spaces/#{key}")}
  end

  defp first_match(_scope, ""), do: :none

  defp first_match(scope, query) do
    case Authorization.readable_spaces(scope, limit: 1, query: query) do
      [space | _] -> {:ok, space}
      [] -> :none
    end
  end

  # The key tells two spaces with the same name apart, so it is the badge — but
  # a personal space is keyed by its owner's account id, which tells nobody
  # anything, so it carries none.
  defp options(spaces) do
    Enum.map(spaces, fn space ->
      %{value: space.key, label: space.name, badge: badge(space)}
    end)
  end

  defp badge(space), do: if(Authorization.personal_space?(space), do: nil, else: space.key)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="space-switcher" phx-hook=".SpaceSwitcher" class="relative">
      <button
        id="space-switcher-button"
        type="button"
        phx-click="toggle_switcher"
        aria-haspopup="menu"
        aria-expanded={to_string(@open?)}
        class="btn btn-ghost btn-sm gap-1.5"
      >
        <.icon name="hero-rectangle-stack" class="size-4" />
        <span class="hidden lg:inline">Spaces</span>
      </button>

      <div
        :if={@open?}
        id="space-switcher-menu"
        data-switcher-menu
        class="absolute right-0 z-50 mt-2 w-72 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <.searchable_select
          id="space-switcher-select"
          name="q"
          query={@query}
          options={@options}
          placeholder="Find a space"
          empty="No space matches that"
          change_event="search"
          submit_event="open_first"
          select_event="open_space"
          value_param="key"
        />

        <ul class="menu mt-1 w-full border-t border-base-300/60 p-0 pt-1">
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
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SpaceSwitcher">
        export default {
          mounted() {
            // A click anywhere else is a reader leaving the menu. The top bar's
            // other menus are <details> and close each other natively; this one
            // is the server's, and this is what keeps it in step with them.
            this.clickAway = event => {
              if (this.el.contains(event.target)) return
              if (!this.el.querySelector("[data-switcher-menu]")) return
              this.pushEvent("close_switcher", {})
            }
            document.addEventListener("click", this.clickAway)

            // Escape closes a menu the reader opened. The menu is wide and the
            // find box has focus, so this is the key a keyboard reader reaches
            // for first, and every other popup on the site answers it.
            this.closeOnEscape = event => {
              if (event.key !== "Escape") return
              if (!this.el.querySelector("[data-switcher-menu]")) return
              event.preventDefault()
              this.pushEvent("close_switcher", {})
              const button = this.el.querySelector("#space-switcher-button")
              if (button) button.focus()
            }
            this.el.addEventListener("keydown", this.closeOnEscape)
          },
          destroyed() {
            document.removeEventListener("click", this.clickAway)
            this.el.removeEventListener("keydown", this.closeOnEscape)
          },
          updated() {
            // Opening this menu closes the native ones, the way they close each
            // other.
            if (!this.el.querySelector("[data-switcher-menu]")) return
            document.querySelectorAll("details[name=topbar-menu][open]").forEach(menu => {
              menu.open = false
            })
          }
        }
      </script>
    </div>
    """
  end
end
