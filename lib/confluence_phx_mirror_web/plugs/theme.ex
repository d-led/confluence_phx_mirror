defmodule ConfluencePhxMirrorWeb.Plugs.Theme do
  @moduledoc """
  Resolves the daisyUI skin from a server-side cookie.

  Built-in skins are compiled into `assets/css/app.css`; site-declared skins
  come from config through `ConfluencePhxMirrorWeb.Skins`, which also emits
  their palette for this request. The first paint already has the right
  `data-theme`, so no client-side script is needed. `system` deliberately sets
  no attribute: daisyUI's dark theme declares `prefersdark`, so the OS
  preference applies.
  """

  import Plug.Conn

  alias ConfluencePhxMirrorWeb.Skins

  def init(opts), do: opts

  def call(conn, _opts) do
    theme = conn.cookies["mirror_theme"]
    theme = if Skins.valid?(theme), do: theme, else: "system"

    conn
    |> assign(:theme, theme)
    |> assign(:skin_css, Skins.style())
  end
end
