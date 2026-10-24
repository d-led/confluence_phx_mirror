// A top-bar menu is a <details> element, and <details> has no light dismiss: a
// reader who opens the theme menu and then clicks the page leaves it hanging
// over the content until they find the same summary again. Escape does nothing
// either.
//
// This lives here rather than in a colocated LiveView hook because the layout is
// also rendered by controllers, into pages no LiveView owns — and a hook in a
// page nobody mounts never runs. A document listener runs everywhere.

const menus = () => document.querySelectorAll("details[name=topbar-menu]")

document.addEventListener("click", event => {
  menus().forEach(menu => {
    if (!menu.open || menu.contains(event.target)) return
    menu.open = false
  })
})

document.addEventListener("keydown", event => {
  if (event.key !== "Escape") return

  menus().forEach(menu => {
    if (!menu.open) return
    event.preventDefault()
    menu.open = false
    // Focus goes back to the control the reader used, not to the top of the
    // document: they were in the middle of something.
    const summary = menu.querySelector("summary")
    if (summary) summary.focus()
  })
})
