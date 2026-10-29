defmodule ConfluencePhxMirrorWeb.Api.V1.SyncRunController do
  @moduledoc """
  The sync runs the mirror keeps: a page at a time, and the whole history as a
  stream.

  A mirror holds one row per run — every schedule tick, every one-page sync an
  administrator asked for, every webhook delivery — so the table grows for as
  long as the mirror exists. The list endpoint is therefore a window with the
  total beside it, and the export is written as it is read rather than
  assembled.

  Administrator-only, both of them: a run's error carries what the node said when
  the sync broke, which is an operator's reading, not a reader's.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Sync.History
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter
  alias ConfluencePhxMirrorWeb.SyncRunExport

  @path "/api/v1/sync-runs"

  def index(conn, params) do
    with :ok <- authorize(conn) do
      start = max(integer(params["start"], 0), 0)
      limit = History.limit(integer(params["limit"], History.default_limit()))
      {runs, total} = History.page(start: start, limit: limit)

      json(
        conn,
        Presenter.list(Enum.map(runs, &History.json/1),
          start: start,
          limit: limit,
          total: total,
          path: @path
        )
      )
    end
  end

  def export(conn, params) do
    with :ok <- authorize(conn) do
      # A stream of a site's whole history is a copy leaving the building, so it
      # is in the audit trail as an operation of its own rather than as a
      # hundred thousand reads.
      ConfluencePhxMirror.Audit.log(
        {:user, conn.assigns.current_user},
        ConfluencePhxMirror.Audit.Entry.new("api.export", "sync_run", "history", %{
          "start" => params["start"],
          "limit" => params["limit"]
        })
      )

      SyncRunExport.download(conn, params)
    end
  end

  defp authorize(conn) do
    if Scope.admin?(Scope.from_assigns(conn.assigns)) do
      :ok
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        "error" => "not_authorized",
        "message" => "The sync history is for administrators."
      })
    end
  end

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_value, default), do: default
end
