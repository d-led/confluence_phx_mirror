defmodule ConfluencePhxMirrorWeb.Plugs.CacheBody do
  @moduledoc """
  `Plug.Parsers` body reader that also keeps the raw body.

  Webhook signatures are computed over the exact bytes Confluence sent, so the
  raw body must survive JSON parsing.
  """

  import Plug.Conn

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, remember(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, remember(conn, chunk)}
      other -> other
    end
  end

  # `Plug.Conn.read_body/2` hands a large body over a chunk at a time, and the
  # plug calls this again for each one; the raw copy a signature is computed
  # over has to be the whole body, not its first chunk.
  defp remember(conn, chunk) do
    assign(conn, :raw_body, Map.get(conn.assigns, :raw_body, "") <> chunk)
  end
end
