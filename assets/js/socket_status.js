// A page whose socket is down looks exactly like a page whose data has not
// changed: both sit still. LiveView's own answer used to be to fall back to
// long-polling — the page kept moving, a poll interval late, invisibly, which is
// worse than being told. That fallback is gone (see `app.js`); this says when
// the page has stopped being live.
//
// There is no window event for it in LiveView 1.2 (it dispatches none for the
// socket's state), so the signal is the class LiveView puts on its own container
// — `phx-connected` while the channel is joined, `phx-loading` or `phx-error`
// otherwise.

const bannerId = "socket-lost";

// A page load, a redirect and a reconnect all pass through "not joined yet", and
// a banner for each of those would be noise. Only a socket that is still down a
// moment later is worth the reader's attention.
const graceMs = 1500;

let timer = null;

const rootView = () => document.querySelector("[data-phx-main]");

const show = () => {
  if (document.getElementById(bannerId)) return;

  const element = document.createElement("div");
  element.id = bannerId;
  element.setAttribute("role", "status");
  element.className =
    "fixed inset-x-0 bottom-0 z-50 flex items-center justify-center gap-2 " +
    "bg-error px-4 py-2 text-xs font-medium text-error-content shadow-lg";
  element.textContent =
    "Not connected: this page is not updating. Reload when the connection is back.";
  document.body.appendChild(element);
};

const hide = () => {
  if (timer) clearTimeout(timer);
  timer = null;
  document.getElementById(bannerId)?.remove();
};

const connected = () =>
  rootView()?.classList.contains("phx-connected") ?? false;

const update = () => {
  if (connected()) return hide();
  if (timer || document.getElementById(bannerId)) return;

  timer = setTimeout(() => {
    timer = null;
    if (!connected()) show();
  }, graceMs);
};

// The container exists only once a LiveView has rendered, so attach when it is
// there: on this load, and after each live navigation, which replaces it. A page
// with no LiveView on it has no container, and that is not a broken socket.
const attach = () => {
  const container = rootView();

  if (!container || container.dataset.socketWatched) return;

  container.dataset.socketWatched = "1";

  new MutationObserver(update).observe(container, {
    attributes: true,
    attributeFilter: ["class"],
  });

  update();
};

attach();
window.addEventListener("phx:page-loading-stop", attach);
