defmodule ConfluencePhxMirrorWeb.Skins.FreshBlue do
  @moduledoc """
  Fresh blue: a calm, high-contrast blue-and-slate skin with a light and a dark
  variant — the look confluence-style tools are known for, without copying any
  published colour tokens.

  This is the mirror's reference `ConfluencePhxMirrorWeb.Skins.Pack` and the
  shipped example of a theme with both palettes: one `colors` map for light, one
  `dark_colors` map for dark, and the reader's variant decides which one paints.

  It is the theme the mirror ships with:

      config :confluence_phx_mirror, theme: "fresh-blue"

  or `CM_THEME=fresh-blue` in a release. An administrator can change the theme
  at runtime from `/admin/settings`; the readers' own choice — system, light,
  dark — never changes the palette, only which half of it is used. See
  `ConfluencePhxMirror.Settings`.

  The colours map onto daisyUI's variables: `base-100` is the card surface,
  `base-200` the canvas behind it, `base-300` the 1px border, and the semantic
  colours are strong enough for icons and badges, with the lighter tints the
  components derive from them (`bg-info/15`). Radii are small and the surfaces
  flat (`depth: 0`), which is what makes dense tables and menus read as one
  system.
  """

  @behaviour ConfluencePhxMirrorWeb.Skins.Pack

  @light %{
    base_100: "#ffffff",
    base_200: "#f6f7f9",
    base_300: "#0a1e3f22",
    base_content: "#16283e",
    primary: "#1565d8",
    primary_content: "#ffffff",
    secondary: "#0b4fa8",
    secondary_content: "#ffffff",
    accent: "#00afcb",
    accent_content: "#12293f",
    neutral: "#43536b",
    neutral_content: "#ffffff",
    info: "#1565d8",
    info_content: "#ffffff",
    success: "#1e9a63",
    success_content: "#ffffff",
    warning: "#d9ac0b",
    warning_content: "#16283e",
    error: "#c0332a",
    error_content: "#ffffff"
  }

  @dark %{
    base_100: "#1c2026",
    base_200: "#121417",
    base_300: "#a9c4e024",
    base_content: "#c6d0da",
    primary: "#5c9cf5",
    primary_content: "#1c2026",
    secondary: "#3a8af0",
    secondary_content: "#1c2026",
    accent: "#00afcb",
    accent_content: "#1c2026",
    neutral: "#23282d",
    neutral_content: "#c6d0da",
    info: "#5c9cf5",
    info_content: "#1c2026",
    success: "#46cb92",
    success_content: "#1c2026",
    warning: "#f0c94a",
    warning_content: "#1c2026",
    error: "#f46f66",
    error_content: "#1c2026"
  }

  @impl true
  def skins do
    [
      %{
        name: "fresh-blue",
        label: "Fresh blue",
        note: "blue and slate, light and dark",
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
