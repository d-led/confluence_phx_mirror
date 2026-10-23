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
    |> assign(:theme_attrs, Skins.attributes(theme, variant))
    |> assign(:skin_css, Skins.style())
  end

  defp variant(conn) do
    name = conn.cookies["mirror_theme"]
    if Skins.variant?(name), do: name, else: "system"
  end
end
