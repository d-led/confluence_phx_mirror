defmodule ConfluencePhxMirrorWeb.Plugs.SiteContext do
  @moduledoc """
  Loads the data every page needs: mirror name, spaces and last sync.

  Kept as a plug so controllers stay free of layout concerns.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sites

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = Scope.for_user(conn.assigns[:current_user])

    conn
    |> assign(:mirror_name, Sites.name())
    |> assign(:mirror_url, Sites.url())
    |> assign(:mirror_host, Sites.host())
    |> assign(:spaces, Authorization.readable_spaces(scope))
    |> assign(:last_sync_run, Mirror.last_successful_sync_run())
    |> assign(:mirror_source, ConfluencePhxMirror.Confluence.Source.source())
  end
end
