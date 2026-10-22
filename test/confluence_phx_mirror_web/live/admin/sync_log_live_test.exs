defmodule ConfluencePhxMirrorWeb.Admin.SyncLogLiveTest do
  @moduledoc """
  The sync log is watched while a sync runs: lines arrive on their own, a reader
  can narrow them to warnings, and a real snapshot leaves its pages in the log.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.Log

  setup %{conn: conn} do
    Log.clear()
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "it shows the lines a sync has already written", %{conn: conn} do
    Log.add(:info, "page created: Architecture Overview", page: 1002)

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "page created: Architecture Overview"
    assert html =~ "page=1002"
  end

  test "a line written while the page is open appears without a reload", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/sync-log")

    refute html =~ "attachment pruned"

    Phoenix.PubSub.broadcast(
      ConfluencePhxMirror.PubSub,
      Log.topic(),
      {:sync_log, entry(:warn, "attachment pruned: diagram.svg")}
    )

    assert render(view) =~ "attachment pruned: diagram.svg"
  end

  test "a reader can narrow the log to warnings and errors", %{conn: conn} do
    Log.add(:info, "page created: Budget")
    Log.add(:warn, "page failed: Broken")

    {:ok, view, html} = live(conn, ~p"/admin/sync-log")
    assert html =~ "page created: Budget"

    html = view |> element("#sync-log-level") |> render_change(%{"level" => "warn"})

    refute html =~ "page created: Budget"
    assert html =~ "page failed: Broken"
  end

  test "a paused reader keeps the lines they were reading", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    view |> element("#sync-log-pause") |> render_click()

    Phoenix.PubSub.broadcast(
      ConfluencePhxMirror.PubSub,
      Log.topic(),
      {:sync_log, entry(:info, "line while paused")}
    )

    refute render(view) =~ "line while paused"
  end

  test "a snapshot leaves the pages it mirrored in the log", %{conn: conn} do
    demo_snapshot!()
    {:ok, _run} = Sync.run(:snapshot)

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "page created: Architecture Overview"
    assert html =~ "finished a snapshot sync"
  end

  defp entry(level, message) do
    %{
      id: System.unique_integer([:monotonic, :positive]),
      at: DateTime.utc_now(),
      level: level,
      message: message,
      run_id: nil,
      details: %{}
    }
  end
end
