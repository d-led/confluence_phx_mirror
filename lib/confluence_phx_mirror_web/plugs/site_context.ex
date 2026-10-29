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
  alias ConfluencePhxMirror.SiteSettings

  # The switcher is a menu. A mirror with a thousand spaces lists a window of
  # them and links to the directory, rather than sending a thousand rows with
  # every page a reader opens.
  @switcher_limit 25

  def init(opts), do: opts

  @doc "How many spaces the shell's switcher lists."
  def switcher_limit, do: @switcher_limit

  def call(conn, _opts) do
    scope = Scope.from_assigns(conn.assigns)

    conn
    |> assign(:mirror_name, Sites.name())
    |> assign(:mirror_url, Sites.url())
    |> assign(:mirror_host, Sites.host())
    |> assign(:site_lang, SiteSettings.lang())
    |> assign(:spaces, Authorization.readable_spaces(scope, limit: @switcher_limit))
    |> assign(:last_sync_run, Mirror.last_successful_sync_run())
    |> assign(:mirror_source, ConfluencePhxMirror.Confluence.Source.source())
  end
end
