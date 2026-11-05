// Read a whiteboard the mirror drew.
//
// A board is a canvas, so the mirror stores it as a picture of itself — and a
// canvas is wide. At the width of a column of prose that picture is a thumbnail
// and the words on it are unreadable. This opens it over the page: zoom with the
// wheel, the buttons or a double click, drag to pan, save it as a file, Escape
// to leave.
//
// Delegated rather than a LiveView hook, like the other modules here: the
// drawing is stored HTML written by a sync, and it is not ours to decorate with
// LiveView attributes. One listener on the document serves every board on every
// page, including the ones a patch brings in.
//
// The picture travels as a data URI, which is also the download: the bytes are
// already here, so a save is a blob made from the same address.

const TRIGGER = "[data-whiteboard-zoom]";
const MIN_SCALE = 0.5;
const MAX_SCALE = 12;
const STEP = 1.25;

let viewer = null;

function open(trigger) {
  if (viewer) return;

  const image = trigger.querySelector("img");
  if (!image) return;

  const previous = document.activeElement;
  const root = document.createElement("div");
  root.className = "whiteboard-viewer";
  root.setAttribute("role", "dialog");
  root.setAttribute("aria-modal", "true");
  root.setAttribute(
    "aria-label",
    trigger.getAttribute("aria-label") || "The drawing",
  );
  root.innerHTML = `
    <div class="whiteboard-viewer-bar">
      <span class="whiteboard-viewer-title"></span>
      <span class="whiteboard-viewer-tools">
        <button type="button" data-action="out" aria-label="Zoom out">−</button>
        <button type="button" data-action="in" aria-label="Zoom in">+</button>
        <button type="button" data-action="fit">Fit</button>
        <button type="button" data-action="download">Download</button>
        <button type="button" data-action="close" aria-label="Close">×</button>
      </span>
    </div>
    <div class="whiteboard-viewer-canvas"><img class="whiteboard-viewer-image" alt=""></div>`;

  const canvas = root.querySelector(".whiteboard-viewer-canvas");
  const picture = root.querySelector(".whiteboard-viewer-image");

  root.querySelector(".whiteboard-viewer-title").textContent = image.alt;
  picture.src = image.currentSrc || image.src;
  picture.alt = image.alt;

  document.body.append(root);
  document.documentElement.classList.add("whiteboard-viewer-open");

  viewer = {
    root,
    canvas,
    picture,
    name: trigger.getAttribute("data-whiteboard-name") || "whiteboard.svg",
    previous,
    scale: 1,
    x: 0,
    y: 0,
  };

  apply();
  listen();
  root.querySelector('[data-action="close"]').focus();
}

// One transform carries both the zoom and the pan, so a drag never waits for a
// layout. Scale 1 is the whole drawing: the canvas fits it with `object-fit`,
// which is the only size a vector has — a data-URI SVG has no pixels of its own
// to call 1:1.
function apply() {
  const { picture, scale, x, y } = viewer;
  picture.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
}

function fit() {
  viewer.scale = 1;
  viewer.x = 0;
  viewer.y = 0;
  apply();
}

// Zoom keeps the point under the pointer where it is: scaling about the centre
// of the sheet drags whatever a reader is looking at away from their cursor,
// which is the one thing a zoom must not do. The anchor is in client
// coordinates; without one the zoom is about the middle, which is what the
// buttons and the keys mean.
//
// With `translate(x, y) scale(s)` about the element's centre, a screen point `c`
// (measured from that centre) is reached by the element point `(c - t) / s`.
// Holding that point under the cursor across a change of scale gives
// `t' = c - (c - t) * s' / s`.
function zoom(factor, anchor) {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, viewer.scale * factor));
  const ratio = next / viewer.scale;

  const box = viewer.canvas.getBoundingClientRect();
  const x = anchor ? anchor.x - box.left - box.width / 2 : 0;
  const y = anchor ? anchor.y - box.top - box.height / 2 : 0;

  viewer.x = x - (x - viewer.x) * ratio;
  viewer.y = y - (y - viewer.y) * ratio;
  viewer.scale = next;
  apply();
}

function close() {
  if (!viewer) return;

  const { root, previous } = viewer;
  viewer = null;

  document.removeEventListener("keydown", onKey);
  root.remove();
  document.documentElement.classList.remove("whiteboard-viewer-open");
  if (previous instanceof HTMLElement) previous.focus();
}

// Panning: one pointer, followed on the window so a drag that leaves the canvas
// keeps arriving. Pointer capture would do the same thing, but it is an
// optimisation with a failure mode (capture on a pointer the browser has already
// released throws), and a window listener has neither.
function startDrag(event) {
  if (event.button !== 0) return;

  event.preventDefault();
  const { canvas } = viewer;
  const origin = { x: event.clientX - viewer.x, y: event.clientY - viewer.y };
  canvas.dataset.dragging = "yes";

  const move = (moveEvent) => {
    if (!viewer) return;
    viewer.x = moveEvent.clientX - origin.x;
    viewer.y = moveEvent.clientY - origin.y;
    apply();
  };

  const stop = () => {
    delete canvas.dataset.dragging;
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", stop);
    window.removeEventListener("pointercancel", stop);
  };

  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", stop);
  window.addEventListener("pointercancel", stop);
}

async function download() {
  const { picture, name } = viewer;
  const blob = await (await fetch(picture.src)).blob();
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");

  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

function act(action) {
  if (action === "in") zoom(STEP);
  else if (action === "out") zoom(1 / STEP);
  else if (action === "fit") fit();
  else if (action === "download") download();
  else if (action === "close") close();
}

// Keys belong to the dialog while it is open: Escape leaves, the arrows pan,
// plus and minus zoom, and Tab stays inside the bar rather than wandering into
// the page behind a modal overlay.
function onKey(event) {
  if (!viewer) return;

  const buttons = [...viewer.root.querySelectorAll("button")];

  switch (event.key) {
    case "Escape":
      event.preventDefault();
      close();
      return;
    case "+":
    case "=":
      event.preventDefault();
      zoom(STEP);
      return;
    case "-":
      event.preventDefault();
      zoom(1 / STEP);
      return;
    case "0":
      event.preventDefault();
      fit();
      return;
    case "ArrowLeft":
    case "ArrowRight":
    case "ArrowUp":
    case "ArrowDown":
      event.preventDefault();
      viewer.x +=
        event.key === "ArrowLeft" ? 40 : event.key === "ArrowRight" ? -40 : 0;
      viewer.y +=
        event.key === "ArrowUp" ? 40 : event.key === "ArrowDown" ? -40 : 0;
      apply();
      return;
    case "Tab": {
      const first = buttons[0];
      const last = buttons[buttons.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  }
}

function listen() {
  const { root, canvas } = viewer;

  root.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (button) act(button.getAttribute("data-action"));
  });

  canvas.addEventListener("pointerdown", startDrag);
  canvas.addEventListener("dblclick", fit);
  // Not passive: a wheel over a drawing means "zoom", and the page behind a
  // modal must not scroll while it does.
  canvas.addEventListener(
    "wheel",
    (event) => {
      event.preventDefault();
      zoom(Math.exp(-event.deltaY * 0.0015), {
        x: event.clientX,
        y: event.clientY,
      });
    },
    { passive: false },
  );

  document.addEventListener("keydown", onKey);
}

document.addEventListener("click", (event) => {
  const target = event.target instanceof Element ? event.target : null;
  const trigger = target && target.closest(TRIGGER);
  if (!trigger) return;

  event.preventDefault();
  open(trigger);
});
