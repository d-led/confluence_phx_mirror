defmodule ConfluencePhxMirrorWeb.Admin.SiteExportController do
  @moduledoc """
  `GET /admin/export/site.zip` — the whole mirror as one static site.

  Every space, every page, every attachment, the site's theme, and the same
  pages as Markdown beside them; all links already pointing at files inside the
  archive. See `ConfluencePhxMirror.Export.Site` for the shape and the rules.

  Administrators only, and the whole site on purpose: a reader's copy of one
  space is offered by the space itself (`/spaces/:key/site.zip`). The admin
  screens are LiveViews with an `on_mount` hook; this is a plain controller, so
  it asks the same question of the same scope rather than trusting the route it
  happens to be mounted at.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirrorWeb.ArchiveDownload

  def index(conn, _params) do
    scope = Scope.from_assigns(conn.assigns)

    if Scope.admin?(scope) do
      ArchiveDownload.send(conn, Export.site_archive(scope), Export.site_archive_name())
    else
      refuse(conn)
    end
  end

  defp refuse(conn) do
    conn
    |> put_status(:forbidden)
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "A whole-site export is for administrators.")
  end
end
