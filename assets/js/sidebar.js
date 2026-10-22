// Collapsible space navigation.
//
// The sidebar is server-rendered: a column beside the content on a laptop, an
// off-canvas drawer on a phone. That is also the no-JavaScript behaviour, so
// nothing breaks before this module runs. It adds the toggle, remembers the
// laptop preference, and gives the drawer the focus and Escape handling a
// keyboard or screen-reader user needs.
//
// Everything is delegated from `document` and looks elements up on demand, so
// LiveView navigations that add or drop the sidebar need no re-initialisation.

const STORAGE_KEY = "mirror:sidebar"
const DESKTOP_QUERY = "(min-width: 1024px)"
const BREAKPOINTS = window.matchMedia(DESKTOP_QUERY)

const state = {open: false, collapsed: readCollapsed()}

function elements() {
  return {
    aside: document.getElementById("mirror-sidebar"),
    backdrop: document.querySelector("[data-sidebar-backdrop]"),
    toggle: document.querySelector("[data-sidebar-toggle]")
  }
}

function readCollapsed() {
  try {
    return window.localStorage.getItem(STORAGE_KEY) === "collapsed"
  } catch (_error) {
    return false
  }
}

function rememberCollapsed() {
  try {
    window.localStorage.setItem(STORAGE_KEY, state.collapsed ? "collapsed" : "expanded")
  } catch (_error) {
    // Private browsing: the preference simply does not persist.
  }
}

const onDesktop = () => BREAKPOINTS.matches

function render() {
  const {aside, backdrop, toggle} = elements()
  if (!aside) return

  const desktop = onDesktop()
  const visible = desktop ? !state.collapsed : state.open

  aside.toggleAttribute("data-open", state.open)
  aside.toggleAttribute("data-collapsed", desktop && state.collapsed)
  // Off-screen must also mean out of the tab order and out of the a11y tree.
  aside.inert = !visible
  if (backdrop) backdrop.hidden = !(state.open && !desktop)
  document.body.classList.toggle("overflow-hidden", state.open && !desktop)
  if (toggle) toggle.setAttribute("aria-expanded", String(visible))
}

function closeDrawer({restoreFocus = true} = {}) {
  if (!state.open) return

  state.open = false
  render()
  const {toggle} = elements()
  if (restoreFocus && toggle) toggle.focus()
}

function toggleNavigation() {
  if (onDesktop()) {
    state.collapsed = !state.collapsed
    rememberCollapsed()
  } else {
    state.open = !state.open
    if (state.open) elements().aside?.focus()
  }

  render()
}

function init() {
  document.addEventListener("click", (event) => {
    if (event.target.closest("[data-sidebar-toggle]")) {
      toggleNavigation()
      return
    }

    if (event.target.closest("[data-sidebar-backdrop]")) {
      closeDrawer()
      return
    }

    // Following a link in the drawer should not leave it open behind the page.
    if (!onDesktop() && event.target.closest("#mirror-sidebar a")) {
      closeDrawer({restoreFocus: false})
    }
  })

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeDrawer()
  })

  BREAKPOINTS.addEventListener("change", () => {
    state.open = false
    render()
  })

  // A LiveView navigation may add the sidebar, drop it, or arrive at a page
  // where it should start closed.
  window.addEventListener("phx:page-loading-stop", () => {
    state.open = false
    render()
  })

  render()
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init)
} else {
  init()
}
