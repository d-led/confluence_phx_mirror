defmodule ConfluencePhxMirror.Export.Site.Chrome do
  @moduledoc """
  The two scripts an exported page needs to be as comfortable as the reader
  screens, and no more.

  `theme_script/0` runs **before the page paints** (a plain script in `<head>`):
  it re-applies the variant a reader pinned — light, dark, or whatever the
  system says — so a page they chose dark does not flash white first.

  `script/0` runs after the document is parsed and adds what a server no longer
  can: folding the page tree away (remembered, keyboard-reachable), cycling the
  theme, and narrowing and paging the lists a large wiki makes long — the
  spaces in the sidebar, the labels in the catalogue, the pages under a label.
  Without JavaScript all of it still works in the plain sense: the tree is
  simply always there, the page follows the system, and every row of every list
  is shown.

  Nothing is fetched: no fonts, no framework, no analytics.
  """

  @theme_script ~S"""
  // The variant a reader last pinned, applied before the page paints.
  (function () {
    "use strict";

    var html = document.documentElement;
    var theme = html.getAttribute("data-theme-name") || "default";
    var builtin = theme === "default";
    var variant = null;

    try {
      variant = window.localStorage.getItem("mirror-export:variant");
    } catch (noStorage) {
      variant = null;
    }

    if (variant !== "light" && variant !== "dark") return;

    if (builtin) {
      html.setAttribute("data-theme", variant);
    } else {
      html.setAttribute("data-theme", theme);
      html.setAttribute("data-scheme", variant);
    }
  })();
  """

  @script ~S"""
  // Reading comfort for a static copy of the mirror.
  //
  // The page tree folds away and the reader's choice is remembered; the theme
  // cycles system → light → dark. Both are delegated from the elements the
  // shell renders, so nothing here has to run twice or know about the page.
  (function () {
    "use strict";

    var DESKTOP = window.matchMedia("(min-width: 1024px)");
    var SIDEBAR_KEY = "mirror-export:sidebar";
    var THEME_KEY = "mirror-export:variant";
    var VARIANTS = ["system", "light", "dark"];

    var html = document.documentElement;
    var aside = document.getElementById("site-sidebar");
    var backdrop = document.querySelector("[data-site-backdrop]");
    var sidebarButton = document.querySelector("[data-site-sidebar-toggle]");
    var themeButton = document.querySelector("[data-site-theme]");

    function remember(key, value) {
      try {
        window.localStorage.setItem(key, value);
      } catch (noStorage) {
        // Private browsing: the preference simply does not persist.
      }
    }

    function recall(key) {
      try {
        return window.localStorage.getItem(key);
      } catch (noStorage) {
        return null;
      }
    }

    // --- the page tree -------------------------------------------------------

    var sidebar = {open: false, collapsed: recall(SIDEBAR_KEY) === "collapsed"};

    function drawSidebar() {
      var desktop = DESKTOP.matches;
      var visible = desktop ? !sidebar.collapsed : sidebar.open;

      if (aside) {
        aside.toggleAttribute("data-open", visible && !desktop);
        aside.toggleAttribute("data-collapsed", desktop && sidebar.collapsed);
        aside.setAttribute("aria-hidden", visible ? "false" : "true");
      }

      if (backdrop) backdrop.hidden = desktop || !sidebar.open;

      if (sidebarButton) {
        var label = visible ? "Hide the page tree" : "Show the page tree";
        sidebarButton.setAttribute("aria-expanded", visible ? "true" : "false");
        sidebarButton.setAttribute("aria-label", label);
        sidebarButton.setAttribute("title", label);
      }

      document.body.classList.toggle("overflow-hidden", !desktop && sidebar.open);
    }

    function toggleSidebar() {
      if (DESKTOP.matches) {
        sidebar.collapsed = !sidebar.collapsed;
        remember(SIDEBAR_KEY, sidebar.collapsed ? "collapsed" : "expanded");
      } else {
        sidebar.open = !sidebar.open;
      }

      drawSidebar();
      if (!aside) return;

      // Focus follows the drawer: into it when it opens, back to the button
      // when it closes under someone who was reading the tree.
      if (sidebar.open) aside.focus();
      else if (aside.contains(document.activeElement)) sidebarButton.focus();
    }

    if (sidebarButton) sidebarButton.addEventListener("click", toggleSidebar);
    if (backdrop) backdrop.addEventListener("click", toggleSidebar);

    DESKTOP.addEventListener("change", function () {
      sidebar.open = false;
      drawSidebar();
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && sidebar.open) {
        sidebar.open = false;
        drawSidebar();
        if (sidebarButton) sidebarButton.focus();
      }
    });

    drawSidebar();

    // --- the theme -----------------------------------------------------------

    var themeName = html.getAttribute("data-theme-name") || "default";
    var builtin = themeName === "default";
    var variant = recall(THEME_KEY);
    if (VARIANTS.indexOf(variant) === -1) variant = "system";

    function drawTheme() {
      if (!themeButton) return;
      var label = "Theme: " + variant + " — switch to " +
        VARIANTS[(VARIANTS.indexOf(variant) + 1) % VARIANTS.length];
      themeButton.setAttribute("aria-label", label);
      themeButton.setAttribute("title", label);
      themeButton.setAttribute("data-variant", variant);
    }

    function applyTheme() {
      if (variant === "system") {
        html.removeAttribute("data-scheme");
        if (builtin) html.removeAttribute("data-theme");
        else html.setAttribute("data-theme", themeName);
      } else if (builtin) {
        html.setAttribute("data-theme", variant);
      } else {
        html.setAttribute("data-theme", themeName);
        html.setAttribute("data-scheme", variant);
      }

      drawTheme();
    }

    if (themeButton) {
      themeButton.addEventListener("click", function () {
        variant = VARIANTS[(VARIANTS.indexOf(variant) + 1) % VARIANTS.length];
        remember(THEME_KEY, variant);
        applyTheme();
      });
    }

    drawTheme();

    // --- long lists ----------------------------------------------------------
    //
    // A copy of a large wiki holds more spaces than a sidebar can show at once,
    // a thousand labels, five thousand pages under one label. The filter
    // narrows a list, the pager walks it, and both only hide rows that are
    // already in the file: with this script blocked every row is there, which
    // is the same list, unasked.

    var SIZE_KEY = "mirror-export:page-size";

    function folded(text) {
      return String(text)
        .toLowerCase()
        .normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "");
    }

    document.querySelectorAll("[data-list]").forEach(function (root) {
      var list = root.querySelector("[data-page-list]");
      if (!list) return;

      var rows = Array.prototype.slice.call(list.children);
      var texts = rows.map(function (row) {
        return folded(row.textContent);
      });

      var field = root.querySelector("[data-filter]");
      var controls = root.querySelector("[data-controls]");
      var sizeField = root.querySelector("[data-page-size]");
      var info = root.querySelector("[data-page-info]");
      var previous = root.querySelector("[data-page-prev]");
      var next = root.querySelector("[data-page-next]");
      var empty = root.querySelector("[data-filter-empty]");

      // Without a pager the list is only narrowed, never cut: every matching
      // row is shown.
      var size = sizeField ? pageSize() : Math.max(1, rows.length);
      var page = 0;
      var query = "";

      function pageSize() {
        var remembered = Number(recall(SIZE_KEY));
        if (remembered > 0) return remembered;
        return Number(sizeField.value) || 100;
      }

      // Every typed word has to be in the row, wherever it is in the row.
      function matching() {
        var words = folded(query).split(/\s+/).filter(Boolean);
        var kept = [];

        for (var i = 0; i < rows.length; i++) {
          var text = texts[i];
          var found = words.every(function (word) {
            return text.indexOf(word) >= 0;
          });

          if (found) kept.push(i);
        }

        return kept;
      }

      function draw() {
        var kept = matching();
        var pages = Math.max(1, Math.ceil(kept.length / size));
        if (page > pages - 1) page = pages - 1;

        var from = page * size;
        var to = Math.min(from + size, kept.length);

        rows.forEach(function (row) {
          row.hidden = true;
        });

        kept.slice(from, to).forEach(function (index) {
          rows[index].hidden = false;
        });

        if (previous) previous.disabled = page <= 0;
        if (next) next.disabled = page >= pages - 1;

        if (info) {
          info.textContent =
            kept.length === 0 ? "" : from + 1 + "–" + to + " of " + kept.length;
        }

        if (empty) empty.hidden = kept.length > 0;
      }

      if (field) {
        field.addEventListener("input", function () {
          query = field.value;
          page = 0;
          draw();
        });
      }

      if (sizeField) {
        sizeField.value = String(size);

        sizeField.addEventListener("change", function () {
          size = Number(sizeField.value) || 100;
          remember(SIZE_KEY, String(size));
          page = 0;
          draw();
        });
      }

      if (previous) {
        previous.addEventListener("click", function () {
          if (page === 0) return;
          page -= 1;
          draw();
        });
      }

      if (next) {
        next.addEventListener("click", function () {
          page += 1;
          draw();
        });
      }

      // The controls are in the file but out of sight until this runs: a page
      // whose script was blocked shows the whole list and no dead buttons.
      if (controls) controls.style.display = "";

      draw();
    });
  })();
  """

  @doc "The variant, applied before the first paint."
  @spec theme_script() :: String.t()
  def theme_script, do: @theme_script

  @doc "Sidebar folding, the theme button, and narrowing and paging long lists."
  @spec script() :: String.t()
  def script, do: @script
end
