defmodule ConfluencePhxMirrorWeb.Plugs.SiteContext do
  @moduledoc """
  Loads the data every page needs: mirror name, spaces and last sync.

  Kept as a plug so controllers stay free of layout concerns.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Mirror

  def init(opts), do: opts

  def call(conn, _opts) do
    mirror = Application.get_env(:confluence_phx_mirror, :mirror, [])

    conn
    |> assign(:mirror_name, Keyword.get(mirror, :name, "Confluence Mirror"))
    |> assign(:spaces, Mirror.list_spaces())
    |> assign(:last_sync_run, Mirror.last_successful_sync_run())
    |> assign(:mirror_source, ConfluencePhxMirror.Confluence.Source.source())
  end
end
