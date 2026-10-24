import {Socket, Presence} from "phoenix"

// One socket for both presence widgets. Every reader joins the site topic, so
// the footer can say how many people are here; a content page also joins its
// own topic, which lists who is reading it.
export default function initPresence() {
  const site = document.querySelector("[data-site-presence]")
  const page = document.querySelector("[data-presence-topic]")
  if (!site && !page) return

  // Phoenix hands a socket the session only when the CSRF token proves the
  // connection came from one of our own pages, and a socket that carries no
  // session is an anonymous reader: it may join the site topic, but every
  // restricted page answers it "not found". LiveView passes this token itself;
  // a socket of our own has to say so.
  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
  const socket = new Socket("/socket", {params: {_csrf_token: csrfToken}})
  const channels = []

  if (site) {
    channels.push(
      join(socket, site.dataset.sitePresence, presence => {
        setCount(site.querySelector("[data-site-presence-count]"), presence)
      })
    )
  }

  if (page) {
    channels.push(
      join(socket, page.dataset.presenceTopic, presence => {
        setCount(page.querySelector("[data-presence-count]"), presence)
        setReaders(page.querySelector("[data-presence-list]"), presence)
      })
    )
  }

  window.addEventListener("beforeunload", () => channels.forEach(channel => channel.leave()))
  socket.connect()
}

function join(socket, topic, render) {
  const channel = socket.channel(topic, {})

  const presence = new Presence(channel)

  presence.onSync(() => render(presence))
  // A channel that could not be joined has no state to show, and asking again
  // would be refused the same way: the reader keeps the number the page was
  // rendered with, and the socket stops retrying.
  channel.join().receive("error", () => {
    render(null)
    channel.leave()
  })

  return channel
}

// One entry per reader: a signed-in user has a single key however many tabs
// they opened. Presence recomputes the whole state on every sync, so each
// render below is a pure function of it.
function readers(presence) {
  return presence.list((_id, {metas}) => metas[0] || {})
}

function setCount(node, presence) {
  // A refused join is not an unknown count: the number the page was rendered
  // with is still the best answer, and a "?" would be a fault the reader cannot
  // act on. The server renders it on every request, so the widget is honest
  // even when the live half of it could not start.
  if (!node || !presence) return

  node.textContent = String(readers(presence).length)
}

function setReaders(list, presence) {
  if (!list || !presence) return

  list.replaceChildren(
    ...readers(presence).map(reader => {
      const item = document.createElement("li")
      item.textContent = reader.user || "Anonymous reader"
      item.className = "truncate"
      return item
    })
  )
}
