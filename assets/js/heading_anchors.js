// Heading permalinks.
//
// Confluence gives every heading an id derived from the page and heading title
// ("id-ÜnïcodeÜnïts—Ölçüm-Overviewsection"), and the mirror keeps the exported
// HTML as it is — so the id a Confluence deep link points at already exists
// here, and one copied here works in Confluence. What is missing is the
// affordance: a link a reader can copy. This adds it, visible on hover and
// reachable by keyboard.
//
// Idempotent on purpose: LiveView patches and the page-loading-stop event both
// run this, and a heading must not collect a second anchor.

const HEADINGS =
  ".confluence-content h1[id], .confluence-content h2[id], .confluence-content h3[id], .confluence-content h4[id], .confluence-content h5[id], .confluence-content h6[id]";

function addHeadingAnchors(root = document) {
  root.querySelectorAll(HEADINGS).forEach((heading) => {
    if (heading.querySelector(":scope > .heading-anchor")) return;

    const link = document.createElement("a");
    link.className = "heading-anchor";
    // The fragment is the id verbatim: ids may be non-ASCII, and a browser
    // matches `#…` against the id it finds in the document.
    link.href = `#${heading.id}`;
    link.setAttribute("aria-label", "Link to this heading");
    link.title = "Link to this heading";
    link.textContent = "#";

    heading.append(link);
  });
}

function init() {
  addHeadingAnchors();
  window.addEventListener("phx:page-loading-stop", () => addHeadingAnchors());
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
