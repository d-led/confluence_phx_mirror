defmodule ConfluencePhxMirror.Export.Site.Chrome do
  @moduledoc """
  The two scripts an exported page needs to be as comfortable as the reader
  screens, and no more.

  `theme_script/0` runs **before the page paints** (a plain script in `<head>`):
  it re-applies the variant a reader pinned — light, dark, or whatever the
  system says — so a page they chose dark does not flash white first.

  `script/0` runs after the document is parsed and adds what a server no longer
  can: folding the page tree away (remembered, keyboard-reachable), and cycling
  the theme. Without JavaScript both still work in the plain sense — the tree
  is simply always there and the page follows the system.

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
  })();
  """

  @doc "The variant, applied before the first paint."
  @spec theme_script() :: String.t()
  def theme_script, do: @theme_script

  @doc "Sidebar folding and the theme button."
  @spec script() :: String.t()
  def script, do: @script
end
