// Ask before a destructive action runs. One action, one question.
//
// Two parties ask about `data-confirm`, and they have to take turns rather than
// both speak: `phoenix_html` asks on `click` (it walks up from whatever was
// clicked and finds the attribute on the button, the link or the form), which
// covers every mouse press; this module asks on `submit`, which is what a
// keyboard press in a form does — Enter submits a form without a click, and a
// resync must not start because the reader typed Enter.
//
// So a click that lands on something confirmable marks the question as already
// asked, and the submit it causes stays quiet. Without that, one press showed
// two dialogs, and a reader who pressed again saw four.
//
// A declined question stops the event before Phoenix or LiveView see it, so
// nothing is sent to the server. `asking` keeps a question from stacking on top
// of itself.
//
// The text belongs to the action, not to this file: it has to name what will be
// lost ("Revoke token “confluence-webhooks”? Integrations stop working.").

let asking = false
let askedByClick = false

const ask = message => {
  if (!message || asking) return true
  asking = true
  try {
    return window.confirm(message)
  } finally {
    asking = false
  }
}

const refuse = event => {
  event.preventDefault()
  event.stopImmediatePropagation()
}

document.addEventListener(
  "click",
  event => {
    const target = event.target instanceof Element ? event.target : null
    if (!target || !target.closest("[data-confirm]")) return
    // phoenix_html is about to ask about exactly this; a submit follows in the
    // same tick, and it must not ask again.
    askedByClick = true
    setTimeout(() => (askedByClick = false), 0)
  },
  true
)

document.addEventListener(
  "submit",
  event => {
    if (!(event.target instanceof HTMLFormElement)) return

    const message = event.target.getAttribute("data-confirm")
    if (askedByClick) {
      askedByClick = false
      return
    }
    if (ask(message)) return
    refuse(event)
  },
  true
)
