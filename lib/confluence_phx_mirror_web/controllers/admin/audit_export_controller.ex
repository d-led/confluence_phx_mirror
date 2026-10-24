defmodule ConfluencePhxMirrorWeb.Admin.AuditExportController do
  @moduledoc """
  `GET /admin/audit/export` — the audit log as a download.

  Streamed, not assembled: the rows are read in batches and each batch is
  written to the socket before the next is read, so the export costs one batch
  of memory whatever the log's size, and a reader who closes the tab stops the
  work at the next chunk. `ConfluencePhxMirror.Audit.Export` owns the formats.

  Administrators only. The audit screen is a LiveView with an `on_mount` hook;
  this is a plain controller, so it asks the same question of the same scope
  rather than trusting the route it happens to be mounted at.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Audit.Export

  @formats %{"ndjson" => :ndjson, "csv" => :csv}

  def index(conn, params) do
    if Scope.admin?(conn.assigns.current_scope) do
      download(conn, format(params))
    else
      refuse(conn)
    end
  end

  defp download(conn, format) do
    conn
    |> put_resp_content_type(content_type(format))
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(format)}"))
    # The log changes as the download runs, so a cached copy would be yesterday's
    # answer presented as today's.
    |> put_resp_header("cache-control", "no-store")
    |> send_chunked(200)
    |> send_rows(format)
  end

  # A client that goes away mid-download is not an error worth logging: the
  # next chunk fails, and that is the whole story.
  defp send_rows(conn, format) do
    Enum.reduce_while(Export.batches(), chunk(conn, Export.header(format)), fn events, conn ->
      case chunk(conn, Export.encode(format, events)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  defp refuse(conn) do
    conn
    |> put_status(:forbidden)
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "The audit log is for administrators.")
  end

  defp format(%{"format" => format}) when is_binary(format) do
    Map.get(@formats, format, :ndjson)
  end

  defp format(_params), do: :ndjson

  defp content_type(:csv), do: "text/csv; charset=utf-8"
  defp content_type(:ndjson), do: "application/x-ndjson; charset=utf-8"

  defp filename(format) do
    "audit-#{Date.utc_today() |> Date.to_iso8601()}.#{extension(format)}"
  end

  defp extension(:csv), do: "csv"
  defp extension(:ndjson), do: "ndjson"
end
