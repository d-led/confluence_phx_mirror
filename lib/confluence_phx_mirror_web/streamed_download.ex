defmodule ConfluencePhxMirrorWeb.StreamedDownload do
  @moduledoc """
  A download written as it is read.

  `batches` is a stream of lists and `encode` turns one list into iodata: each
  batch is sent before the next one is read, so the download costs one batch of
  memory whatever the table's size, and a reader who closes the tab stops the
  work at the next chunk instead of leaving a query running.
  """

  import Plug.Conn

  @doc """
  Sends `batches` as a file called `filename`, with `header` before them.

  An empty `header` is skipped: an empty chunk would end the body, which is why
  JSON lines, whose first line is a record, passes `[]`.

  The content type is the caller's, set from a literal before this is called:
  what a response type is, is a decision made in code, not a value carried from
  a request.
  """
  @spec send_file(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def send_file(conn, opts) do
    conn
    |> put_resp_header("content-disposition", disposition(opts))
    # The history grows as the download runs, so a cached copy would be
    # yesterday's answer presented as today's.
    |> put_resp_header("cache-control", "no-store")
    |> send_chunked(200)
    |> then(&write_header(&1, Keyword.get(opts, :header, [])))
    |> then(&write_batches(&1, Keyword.fetch!(opts, :batches), Keyword.fetch!(opts, :encode)))
  end

  defp disposition(opts), do: ~s(attachment; filename="#{Keyword.fetch!(opts, :filename)}")

  defp write_header(conn, []), do: conn

  defp write_header(conn, header) do
    case chunk(conn, header) do
      {:ok, conn} -> conn
      # The client is gone. Nothing to report: the download it asked for is
      # over, and the next chunk would only fail the same way.
      {:error, _closed} -> conn
    end
  end

  defp write_batches(conn, batches, encode) do
    Enum.reduce_while(batches, conn, fn batch, conn ->
      case chunk(conn, encode.(batch)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end
end
