defmodule ConfluencePhxMirror.Desktop.Web.DispatchTest do
  @moduledoc """
  The marker one row of the app leaves for another.

  A second copy of the tool has to tell "the port is taken by something else"
  from "the port is taken by *me*", and it asks by request: a response header
  that only this router sets. The whole single-instance guard rests on that
  header being on every answer the window's origin gives — so it is tested on a
  page that needs nothing running, and then on the first-run form, which takes a
  different branch of the same router.
  """

  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  alias ConfluencePhxMirror.Desktop.Web.Dispatch

  test "every answer from the window's origin says which app it came from" do
    conn = Dispatch.call(conn("GET", "/__tool/assets/app.js"), [])

    assert conn.status == 200
    assert get_resp_header(conn, Dispatch.instance_header()) == ["1"]
  end

  test "the first-run form is marked too, though it is answered by a different branch" do
    # Nothing is configured in a throwaway `HOME`, so `/` is the setup form —
    # the one page this router renders itself rather than through `Tool`.
    conn = Dispatch.call(conn("GET", "/"), [])

    assert conn.status == 200
    assert get_resp_header(conn, Dispatch.instance_header()) == ["1"]
  end

  test "the tool's screens are where the router says they are" do
    conn = Dispatch.call(conn("GET", "/__tool/assets/app.js"), [])

    assert get_resp_header(conn, "content-type") |> hd() =~ "javascript"
    # `no-store`: a cached copy of this file once made the spaces filter silently
    # stop typing, and there is no version in its URL to bust the cache.
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
