defmodule ConfluencePhxMirror.Desktop.Web.Dispatch do
  @moduledoc """
  One origin, two sets of screens.

  Everything the mirror serves — the home page, the catalogs, a page, the search
  LiveView, `/admin` and every screen under it — is answered by the server's own
  endpoint, mounted here unchanged. The tool's own few screens are answered by
  `ConfluencePhxMirror.Desktop.Web.Tool` under `/__tool`, which is a path no
  server route or space key can collide with.

  Mounting the endpoint rather than starting it means one listener and one
  origin: the window's pages, its websocket and the tool's form share a port, a
  cookie jar and a `Host`, which is the only arrangement where a session saved
  on one screen is the session the next screen reads.
  """

  @behaviour Plug

  import Plug.Conn,
    only: [put_resp_content_type: 2, put_resp_header: 3, register_before_send: 2, send_resp: 3]

  alias ConfluencePhxMirror.Desktop.Settings
  alias ConfluencePhxMirror.Desktop.Web.{Page, Tool}

  @tool "/__tool"

  # Every response the window's origin sends says which app it came from, so a
  # copy starting up can tell "the port is taken by something else" from "the
  # port is taken by *me*" — see `Desktop.Web.Server.choose_port/0`. A response
  # header rather than a page's text: it is one place, it survives a rewrite of
  # the markup, and a deployed mirror (which does not serve `/__tool` and never
  # goes through this module) cannot answer it.
  @instance_header "x-confluence-export"

  @doc "The header that marks a response as coming from a desktop copy."
  @spec instance_header() :: String.t()
  def instance_header, do: @instance_header

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> register_before_send(&put_resp_header(&1, @instance_header, "1"))
    |> route()
  end

  defp route(conn) do
    cond do
      tool?(conn.request_path) ->
        Tool.call(conn, [])

      first_run?(conn) ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, Page.setup(%{}))

      true ->
        ConfluencePhxMirrorWeb.Endpoint.call(conn, [])
    end
  end

  defp tool?(path), do: path == @tool or String.starts_with?(path, @tool <> "/")

  # The first run: nothing has been mirrored yet and the mirror has no folder to
  # read, so the one screen worth showing is the one that asks where the site is.
  # Answered here rather than redirected to, so the window has one address from
  # the first launch and the form is a page, not a detour.
  defp first_run?(conn) do
    conn.method == "GET" and conn.request_path == "/" and not Settings.configured?()
  end
end
