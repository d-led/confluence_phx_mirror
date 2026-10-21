defmodule ConfluencePhxMirrorWeb.Plugs.CacheBody do
  @moduledoc """
  `Plug.Parsers` body reader that also keeps the raw body.

  Webhook signatures are computed over the exact bytes Confluence sent, so the
  raw body must survive JSON parsing.
  """

  import Plug.Conn

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, assign(conn, :raw_body, body)}
      {:more, partial, conn} -> {:more, partial, assign(conn, :raw_body, partial)}
      other -> other
    end
  end
end
