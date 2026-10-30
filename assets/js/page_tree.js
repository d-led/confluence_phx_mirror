// Opening a sidebar branch.
//
// The page tree ships closed except for the trail to the page being read: a
// space with a thousand pages is a thousand links nobody asked for. The
// chevron asks the server for one node's children (`/spaces/:key/tree/:id`),
// which answers with the same `li`s a rendered branch has, and remembers the
// branch so opening it again costs nothing.
//
// Delegated from `document` and looking elements up per click, so a LiveView
// patch that re-renders the sidebar needs no re-initialisation.

async function expand(branch, toggle) {
  const space = document.getElementById("page-tree")?.dataset.treeSpace;
  if (!space) return;

  if (branch.dataset.loaded !== "true") {
    const response = await fetch(
      `/spaces/${encodeURIComponent(space)}/tree/${toggle.dataset.treeToggle}`,
      {
        headers: { accept: "text/html" },
      },
    );
    // A branch nobody may open is a branch that stays closed.
    if (!response.ok) return;

    branch.insertAdjacentHTML("beforeend", await response.text());
    branch.dataset.loaded = "true";
  }

  const opened = toggle.getAttribute("aria-expanded") !== "true";
  toggle.setAttribute("aria-expanded", String(opened));
  branch.classList.toggle("hidden", !opened);
}

document.addEventListener("click", (event) => {
  const toggle = event.target.closest("[data-tree-toggle]");
  if (!toggle) return;

  const branch = toggle
    .closest("li")
    ?.querySelector(":scope > [data-tree-children]");
  if (!branch) return;

  event.preventDefault();
  expand(branch, toggle).catch((error) =>
    console.error("the page tree:", error),
  );
});
