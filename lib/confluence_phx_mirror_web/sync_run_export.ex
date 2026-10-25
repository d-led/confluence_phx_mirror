defmodule ConfluencePhxMirrorWeb.SyncRunExport do
  @moduledoc """
  The whole sync history as a file: `/admin/sync-runs/export` for an
  administrator in a browser, `/api/v1/sync-runs/export` for a token.

  Two formats, because two readers ask: **CSV** for the spreadsheet an operator
  opens to answer "how many runs failed last week", **JSON lines** for the script
  that reads a hundred thousand of them without holding a hundred thousand of
  them. Both are streamed — see `ConfluencePhxMirrorWeb.StreamedDownload` — and
  both come from `ConfluencePhxMirror.Sync.History`, so the file and the API
  cannot disagree about what a run is.
  """

  alias ConfluencePhxMirror.Sync.History
  alias ConfluencePhxMirrorWeb.StreamedDownload

  import Plug.Conn, only: [put_resp_content_type: 2]

  @formats %{"csv" => :csv, "jsonl" => :jsonl, "ndjson" => :jsonl}

  @doc "Sends the history as a download, in the format the request asks for."
  def download(conn, params) do
    format = format(params)

    conn
    |> put_content_type(format)
    |> StreamedDownload.send_file(
      filename: filename(format),
      header: History.header(format),
      batches: History.batches(),
      encode: &History.encode(format, &1)
    )
  end

  defp format(%{"format" => format}) when is_binary(format) do
    Map.get(@formats, String.downcase(format), :csv)
  end

  defp format(_params), do: :csv

  # A literal per format, chosen from an atom: what a response type is, is a
  # decision made in code, never a value carried from a request. The charset is
  # left to `put_resp_content_type/2`, which appends it once.
  defp put_content_type(conn, :csv), do: put_resp_content_type(conn, "text/csv")

  defp put_content_type(conn, :jsonl),
    do: put_resp_content_type(conn, "application/x-ndjson")

  defp filename(format) do
    "sync-runs-#{Date.utc_today() |> Date.to_iso8601()}.#{extension(format)}"
  end

  defp extension(:csv), do: "csv"
  defp extension(:jsonl), do: "jsonl"
end
