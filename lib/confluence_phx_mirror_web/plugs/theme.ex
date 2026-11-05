defmodule ConfluencePhxMirrorWeb.Plugs.Theme do
  @moduledoc """
  Resolves the site's theme and the reader's variant.

  The theme is the administrator's choice (`Skins.theme/0`); the variant is the
  reader's own — `system`, `light` or `dark` — kept in a cookie. Both land on
  `<html>` as attributes, so the first paint is already right and no JavaScript
  is involved. `system` leaves the palette to the OS.
  """

  import Plug.Conn

  alias ConfluencePhxMirrorWeb.Skins

  def init(opts), do: opts

  def call(conn, _opts) do
    theme = Skins.theme()
    variant = variant(conn)

    conn
    |> assign(:theme, theme)
    |> assign(:variant, variant)
    # `data-variant` is the reader's choice, not the palette: the theme menu
    # marks the entry they are on from this attribute, so a cached page cannot
    # disagree with the menu.
    |> assign(:theme_attrs, Map.put(Skins.attributes(theme, variant), "data-variant", variant))
    |> assign(:skin_css, Skins.style())
  end

  defp variant(conn) do
    name = conn.cookies["mirror_theme"]
    if Skins.variant?(name), do: name, else: "system"
  end
end
