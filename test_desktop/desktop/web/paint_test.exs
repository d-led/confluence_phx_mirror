defmodule ConfluencePhxMirror.Desktop.Web.PaintTest do
  @moduledoc """
  The one claim only a window can make: that a screen was drawn.

  Every other test in this repository asks a server questions, and a server that
  serves HTML has not drawn anything — which is how a window that judged its own
  splash page a foreign link passed the whole suite while opening a console and a
  browser instead of the tool. The tool's pages therefore report the screen they
  drew, and this is what that report means.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias ConfluencePhxMirror.Desktop.Web.{Dispatch, Page, Paint}

  setup do
    Paint.forget()
    :ok
  end

  test "a window that has drawn nothing says so, and says it differently from a missing page" do
    conn = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert conn.status == 503
    assert conn.resp_body =~ "no window has drawn a screen yet"
  end

  test "the report names the screen the window drew" do
    painted = Dispatch.call(conn("POST", "/__tool/painted?path=%2F__tool%2Fsetup"), [])

    assert painted.status == 204

    report = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert report.status == 200
    assert report.resp_body =~ "painted /__tool/setup at"
  end

  test "the last screen a window drew is the one reported" do
    Dispatch.call(conn("POST", "/__tool/painted?path=%2F__tool%2Fsetup"), [])
    Dispatch.call(conn("POST", "/__tool/painted?path=%2F__tool%2Fspaces"), [])

    report = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert report.resp_body =~ "painted /__tool/spaces at"
  end

  test "the first screen a window lands on carries the report" do
    # A launch with nothing configured lands on the setup form, so that is the
    # page a smoke test of a packaged build will be waiting on.
    assert Page.setup(%{}) =~ ~s(fetch("/__tool/painted?path=")
  end

  test "the screen behind the account menu carries it too" do
    assert Page.home() =~ ~s(fetch("/__tool/painted?path=")
  end
end
