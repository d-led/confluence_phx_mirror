defmodule ConfluencePhxMirrorWeb.HealthController do
  @moduledoc "Liveness/readiness probe with a database check and sync freshness."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo

  def show(conn, _params) do
    database = database_status()
    stats = Mirror.stats()
    last_sync = Mirror.last_successful_sync_run()

    status = if database == "ok", do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{
      status: if(status == 200, do: "ok", else: "degraded"),
      database: database,
      pages: stats.pages,
      spaces: stats.spaces,
      attachments: stats.attachments,
      last_sync_at: last_sync && last_sync.finished_at,
      source: Source.source() |> Module.split() |> List.last()
    })
  end

  defp database_status do
    Repo.query!("SELECT 1")
    "ok"
  rescue
    _ -> "unavailable"
  end
end
