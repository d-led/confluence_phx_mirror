defmodule ConfluencePhxMirrorWeb.Admin.SyncLogLiveTest do
  @moduledoc """
  The sync log is watched while a sync runs: lines arrive on their own, a reader
  can narrow them to warnings, and a real snapshot leaves its pages in the log.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Confluence.Traffic
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.Log

  setup %{conn: conn} do
    Log.clear()
    Traffic.reset()
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

  test "the page follows new lines until the reader pauses it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    assert has_element?(view, "#sync-log[data-follow=true]")
    assert has_element?(view, "#sync-log-follow[aria-pressed=true]")

    view |> element("#sync-log-follow") |> render_click()

    assert has_element?(view, "#sync-log[data-follow=false]")
    assert has_element?(view, "#sync-log-follow[aria-pressed=false]")
  end

  test "a paused reader still gets the lines, the page just stops following them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    view |> element("#sync-log-follow") |> render_click()

    Phoenix.PubSub.broadcast(
      ConfluencePhxMirror.PubSub,
      Log.topic(),
      {:sync_log, entry(:info, "line while paused")}
    )

    assert render(view) =~ "line while paused"
    assert has_element?(view, "#sync-log[data-follow=false]")
  end

  test "scrolling back stops the page from following", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    view |> render_hook("scrolled", %{"follow" => false})

    assert has_element?(view, "#sync-log-follow[aria-pressed=false]")

    view |> render_hook("scrolled", %{"follow" => true})

    assert has_element?(view, "#sync-log-follow[aria-pressed=true]")
  end

  test "a snapshot leaves the pages it mirrored in the log", %{conn: conn} do
    demo_snapshot!()
    {:ok, _run} = Sync.run(:snapshot)

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "page created: Architecture Overview"
    assert html =~ "finished a snapshot sync"
  end

  test "a call to Confluence is a line with its status and its latency", %{conn: conn} do
    Log.add(:debug, "GET /wiki/rest/api/content?spaceKey=ENG 200 42 ms",
      kind: :http,
      method: "GET",
      status: 200,
      ms: 42,
      attempt: 2,
      waited: 180
    )

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "GET /wiki/rest/api/content?spaceKey=ENG 200 42 ms"
    # What the message already says is not repeated in the details.
    refute html =~ "status=200"
    assert html =~ "attempt=2"
    assert html =~ "waited=180"
  end

  test "the page adds up what the run's calls have cost so far", %{conn: conn} do
    Traffic.request(200, 40, 1_024)

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "1 call · 1.0 KB · avg 40 ms"
  end

  test "the run's summary line carries the answers the site gave", %{conn: conn} do
    Log.add(:info, "http: 3 calls · 512 B · avg 12 ms",
      kind: :http_summary,
      answers: "200×3"
    )

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "http: 3 calls"
    assert html =~ "answers=200×3"
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
