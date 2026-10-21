defmodule ConfluencePhxMirrorWeb.Api.V1.StatsController do
  @moduledoc "Mirror statistics and freshness."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.Time

  def show(conn, _params) do
    last_sync = Mirror.last_successful_sync_run()
    stats = Mirror.stats()

    json(conn, %{
      "stats" => stats,
      "lastSync" =>
        last_sync &&
          %{
            "id" => last_sync.id,
            "mode" => last_sync.mode,
            "status" => last_sync.status,
            "startedAt" => Time.iso(last_sync.started_at),
            "finishedAt" => Time.iso(last_sync.finished_at),
            "stats" => last_sync.stats
          },
      "source" => ConfluencePhxMirror.Confluence.Source.source() |> Module.split() |> List.last()
    })
  end
end
