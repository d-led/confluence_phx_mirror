defmodule ConfluencePhxMirrorWeb.Plugs.Theme do
  @moduledoc """
  Resolves the daisyUI skin from config or a server-side cookie.

  A skin pinned for the whole site (`config :confluence_phx_mirror, :site_skin`)
  wins for every reader; otherwise the reader's cookie decides. Built-in skins
  are compiled into `assets/css/app.css`; site-declared skins and packs come
  from `ConfluencePhxMirrorWeb.Skins`, which also emits their palette for this
  request. The first paint already has the right `data-theme`, so no
  client-side script is needed. `system` deliberately sets no attribute:
  daisyUI's dark theme declares `prefersdark`, so the OS preference applies.
  """

  import Plug.Conn

  alias ConfluencePhxMirrorWeb.Skins

  def init(opts), do: opts

  def call(conn, _opts) do
    theme = Skins.site_skin() || reader_skin(conn)

    conn
    |> assign(:theme, theme)
    |> assign(:skin_css, Skins.style())
  end

  defp reader_skin(conn) do
    theme = conn.cookies["mirror_theme"]
    if Skins.valid?(theme), do: theme, else: "system"
  end
end
