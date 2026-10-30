defmodule ConfluencePhxMirrorWeb.ArchiveDownload do
  @moduledoc """
  A ZIP archive as a download, in the two shapes this mirror offers.

  `send/3` generates the archive while it sends it: `ConfluencePhxMirror.Export.Zip`
  turns the entries into chunks, and each chunk is written before the next entry
  is even built, so the cost of a download is one entry of memory on the server
  and one entry on its way. Nothing can be resumed from a response like that,
  and it says so.

  `send_file/4` sends an archive that already exists on disk — what
  `ConfluencePhxMirror.Export.Artifact` prepared. It carries a length, and it
  answers `Range` requests with the bytes asked for, which is what a browser
  needs to resume a download that stopped.

  A reader who closes the tab is not an error in either shape: the next chunk
  fails, or the file send ends, and the work stops there.
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
    # The archive is produced while it is sent and no byte in it means the same
    # thing twice, so a range has nothing to point at and a download cannot be
    # resumed. Saying so is the honest half: without it a browser offers to
    # resume, asks for the rest, and is handed the whole archive from the start
    # — worse than starting again on purpose.
    |> put_resp_header("accept-ranges", "none")
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

  @doc """
  Sends the archive at `path` as `filename`, honouring a `Range` request.

  A browser that lost a download asks for the rest of the file and expects the
  bytes from that offset with a `206`; a request with no range, or one this
  server cannot make sense of, gets the whole file.
  """
  @spec send_file(Plug.Conn.t(), Path.t(), String.t()) :: Plug.Conn.t()
  def send_file(conn, path, filename) do
    size = path |> File.stat!() |> Map.fetch!(:size)

    conn
    |> put_resp_content_type("application/zip")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("accept-ranges", "bytes")
    |> deliver(path, size, conn |> get_req_header("range") |> List.first())
  end

  defp deliver(conn, path, size, nil), do: send_file_response(conn, 200, path, 0, size, nil)

  defp deliver(conn, path, size, range) do
    case slice(range, size) do
      {from, to} ->
        send_file_response(conn, 206, path, from, to - from + 1, "bytes #{from}-#{to}/#{size}")

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # `bytes=START-` is the shape a browser's resume sends; `bytes=START-END` is
  # the one a player asks for. Anything else — several ranges, a unit that is
  # not bytes, a start past the end — is not something this server answers with
  # a part, so the whole file is the answer.
  defp slice("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      [first, last] ->
        with {from, ""} <- Integer.parse(first),
             true <- from < size do
          {from, last |> Integer.parse() |> to_end(from, size)}
        else
          _ -> :unsatisfiable
        end

      _other ->
        :unsatisfiable
    end
  end

  defp slice(_other, _size), do: :unsatisfiable

  defp to_end({last, ""}, _from, size), do: min(last, size - 1)
  defp to_end(_open, _from, size), do: size - 1

  # The path is the artifact registry's own (a fixed name inside the folder the
  # deployment configured), and the offset and length are numbers parsed from a
  # `Range` header — so the range decides *which part* of a known file is sent,
  # never which file.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_file_response(conn, status, path, offset, length, content_range) do
    conn
    |> put_resp_header_maybe("content-range", content_range)
    |> send_file(status, path, offset, length)
  end

  defp put_resp_header_maybe(conn, _name, nil), do: conn
  defp put_resp_header_maybe(conn, name, value), do: put_resp_header(conn, name, value)
end
