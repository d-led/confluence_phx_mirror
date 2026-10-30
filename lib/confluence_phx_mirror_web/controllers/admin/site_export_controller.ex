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
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.Artifact
  alias ConfluencePhxMirrorWeb.ArchiveDownload

  def index(conn, params) do
    scope = Scope.from_assigns(conn.assigns)

    if Scope.admin?(scope) do
      download(conn, scope, params)
    else
      refuse(conn)
    end
  end

  # A prepared archive is a file on disk, so the answer carries a length and
  # honours a range — a download that stopped where the proxy blinked can be
  # resumed. Without one, the archive is generated while it is sent: the same
  # bytes, none of the disk, and no way to resume something that does not exist
  # yet. Which shape a deployment gets is `export.prepared`.
  defp download(conn, scope, params) do
    # The page that offered the button cannot see this request, so the request
    # says it arrived: the press that started nothing is the one an operator
    # presses again three times.
    Artifact.begin_download(params["export"])

    version = Export.site_archive_version()

    case Artifact.status(Export.site_artifact()) do
      # An archive of the content in force now: the file the browser asked for
      # already exists, so it is a file send rather than a minute of work.
      {:ready, %{at: at, version: ^version}} ->
        # The trail says which shape left the building: the file that was
        # already on disk, or one built for this request.
        Audit.log(actor(scope), Export.audit_event_site_exported(true))

        conn
        |> ArchiveDownload.send_file(
          Artifact.path(Export.site_artifact()),
          Export.site_archive_name(at)
        )

      _absent_building_or_out_of_date ->
        Audit.log(actor(scope), Export.audit_event_site_exported(false))

        ArchiveDownload.send(conn, Export.site_archive(scope), Export.site_archive_name())
    end
  end

  # The administrator who asked. `index/2` has already refused everyone else, so
  # the scope here always carries one.
  defp actor(%Scope{user: %{} = user}), do: {:user, user}

  defp refuse(conn) do
    conn
    |> put_status(:forbidden)
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "A whole-site export is for administrators.")
  end
end
