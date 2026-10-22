// Ask before a destructive action runs.
//
// Any element carrying `data-confirm="…"` asks the question first: a click on
// the element, or a submit of the form it belongs to. Declining cancels the
// event before Phoenix or LiveView see it, so nothing is sent to the server.
//
// The text belongs to the action, not to this file: it has to name what will be
// lost ("Revoke token “confluence-webhooks”? Integrations stop working.").

const question = element => element && element.getAttribute("data-confirm")

const allow = event => {
  const target = event.target instanceof Element ? event.target : null
  if (!target) return true

  const confirmed = question(target.closest("[data-confirm]")) ?? question(target.closest("form"))
  if (!confirmed) return true
  if (window.confirm(confirmed)) return true

  event.preventDefault()
  event.stopImmediatePropagation()
  return false
}

document.addEventListener("click", allow, true)
document.addEventListener("submit", allow, true)
