defmodule ConfluencePhxMirrorWeb.Admin.SyncRunsExportController do
  @moduledoc """
  `GET /admin/sync-runs/export` — the sync history as a download.

  The dashboard's runs table shows the last eight, because that is what an
  operator can read at a glance; the table behind it keeps every run the mirror
  ever did. This is the way out of that window: `?format=csv` for a spreadsheet,
  `?format=jsonl` for a script, both streamed and both the whole history.

  Administrators only. The admin screens are LiveViews with an `on_mount` hook;
  this is a plain controller, so it asks the same question of the same scope.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirrorWeb.SyncRunExport

  def index(conn, params) do
    if Scope.admin?(Scope.from_assigns(conn.assigns)) do
      SyncRunExport.download(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "The sync history is for administrators.")
    end
  end
end
