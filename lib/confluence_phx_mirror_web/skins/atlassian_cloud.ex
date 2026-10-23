defmodule ConfluencePhxMirrorWeb.Skins.AtlassianCloud do
  @moduledoc """
  Atlassian Cloud as a whole-site skin: one look for every reader, light or
  dark depending on what the reader's OS prefers.

  This is the mirror's reference `ConfluencePhxMirrorWeb.Skins.Pack` and the
  shipped example of a *whole skin*. Apply it to the whole site with:

      config :confluence_phx_mirror, :site_skin, "atlassian-cloud"

  or `CM_SITE_SKIN=atlassian-cloud` in a release. It stays out of the reader's
  picker (`selectable: false`), because a site skin is a deployment decision,
  not a preference.

  The colours are Atlassian's Cloud design tokens mapped onto daisyUI's
  variables: `base-100` is the card surface, `base-200` the canvas behind it,
  `base-300` the 1px border token, and the semantic colours are the *bold*
  tokens — Atlassian's subtle banner backgrounds are these at low opacity
  (`bg-info/15`), which the mirror's components already use. Radii are
  Atlassian's 3px controls and 6px cards, with flat surfaces (`depth: 0`).
  """

  @behaviour ConfluencePhxMirrorWeb.Skins.Pack

  @light %{
    base_100: "#ffffff",
    base_200: "#f7f8f9",
    base_300: "#091e4224",
    base_content: "#172b4d",
    primary: "#0c66e4",
    primary_content: "#ffffff",
    secondary: "#0055cc",
    secondary_content: "#ffffff",
    accent: "#00b8d9",
    accent_content: "#172b4d",
    neutral: "#44546f",
    neutral_content: "#ffffff",
    info: "#0c66e4",
    info_content: "#ffffff",
    success: "#22a06b",
    success_content: "#ffffff",
    warning: "#e2b203",
    warning_content: "#172b4d",
    error: "#c9372c",
    error_content: "#ffffff"
  }

  @dark %{
    base_100: "#1d2125",
    base_200: "#111214",
    base_300: "#a6c5e229",
    base_content: "#c7d1db",
    primary: "#579dff",
    primary_content: "#1d2125",
    secondary: "#388bff",
    secondary_content: "#1d2125",
    accent: "#00b8d9",
    accent_content: "#1d2125",
    neutral: "#22272b",
    neutral_content: "#c7d1db",
    info: "#579dff",
    info_content: "#1d2125",
    success: "#4bce97",
    success_content: "#1d2125",
    warning: "#f5cd47",
    warning_content: "#1d2125",
    error: "#f87168",
    error_content: "#1d2125"
  }

  @impl true
  def skins do
    [
      %{
        name: "atlassian-cloud",
        label: "Atlassian Cloud",
        icon: "hero-building-office-2",
        selectable: false,
        scheme: :light,
        colors: @light,
        dark_colors: @dark,
        radius: %{selector: "0.1875rem", field: "0.1875rem", box: "0.375rem"},
        border: "1px",
        depth: "0",
        noise: "0"
      }
    ]
  end
end
