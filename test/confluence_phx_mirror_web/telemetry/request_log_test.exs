defmodule ConfluencePhxMirrorWeb.Telemetry.RequestLogTest do
  @moduledoc """
  The request log answers "what did readers ask for" and nothing about probes:
  Fly's health check runs every fifteen seconds per Machine, and a log full of
  `/health` is a log with the interesting lines hidden in it.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    # The suite runs at :warning; request lines are :info.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "a page request is one readable line", %{conn: conn} do
    log = capture_log(fn -> get(conn, ~p"/spaces") end)

    assert log =~ ~r/GET \/spaces 200 in \d/
  end

  test "the health probe is not logged at all", %{conn: conn} do
    log = capture_log(fn -> get(conn, ~p"/health") end)

    assert log == ""
  end
end
