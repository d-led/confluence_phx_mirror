defmodule ConfluencePhxMirrorWeb.ArchiveDownload do
  @moduledoc """
  A ZIP archive as a download, streamed entry by entry.

  The archive is never assembled: `ConfluencePhxMirror.Export.Zip` turns the
  entries into chunks, and each chunk is written before the next entry is even
  built. So the cost of a download is one entry of memory on the server and one
  entry on its way — a whole site's pages and attachments do not have to fit
  anywhere at once.

  A reader who closes the tab is not an error: the next chunk fails and the
  work stops there.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Export.Zip

  # A site is hundreds of thousands of files; one socket write per file spends
  # more time in the kernel than in the archive. Entries are gathered into
  # batches first — the first really goes out only when the batch is full, so a
  # reader still sees the download start immediately.
  @batch 64

  @doc "Sends `entries` — `{path, data_or_fun}` pairs — as `filename`."
  @spec send(Plug.Conn.t(), Enumerable.t(), String.t()) :: Plug.Conn.t()
  def send(conn, entries, filename) do
    conn
    |> put_resp_content_type("application/zip")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    # An export is a snapshot of right now, so a cached copy would be
    # yesterday's answer presented as today's.
    |> put_resp_header("cache-control", "no-store")
    |> send_chunked(200)
    |> stream(entries)
  end

  defp stream(conn, entries) do
    entries
    |> Zip.chunks()
    |> Stream.chunk_every(@batch)
    |> Enum.reduce_while(conn, fn data, conn ->
      case chunk(conn, IO.iodata_to_binary(data)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end
end
