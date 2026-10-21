import {Socket, Presence} from "phoenix"

// Tracks the reader on `page:<id>` and renders who else is reading.
// Phoenix Presence recomputes the full state on every sync, so the render is
// deliberately a pure function of that state.
export default function initPagePresence() {
  const container = document.querySelector("[data-presence-topic]")
  if (!container) return

  const topic = container.dataset.presenceTopic
  const socket = new Socket("/socket", {params: {}})
  const channel = socket.channel(topic, {})
  const presence = new Presence(channel)

  const count = container.querySelector("[data-presence-count]")
  const list = container.querySelector("[data-presence-list]")

  presence.onSync(() => {
    const readers = presence.list((_id, {metas}) => metas[0] || {})

    if (count) count.textContent = String(readers.length)

    if (list) {
      list.replaceChildren(
        ...readers.map(reader => {
          const item = document.createElement("li")
          item.textContent = reader.user || "Anonymous reader"
          item.className = "truncate"
          return item
        })
      )
    }
  })

  channel.join().receive("error", () => {
    if (count) count.textContent = "?"
  })

  window.addEventListener("beforeunload", () => channel.leave())
  socket.connect()
}
