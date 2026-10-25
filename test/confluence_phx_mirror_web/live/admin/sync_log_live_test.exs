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

    write(:warn, "attachment pruned: diagram.svg")

    assert render(view) =~ "attachment pruned: diagram.svg"
  end

  test "the count says when it is a ceiling, because the log slides", %{conn: conn} do
    Log.add(:info, "page created: Budget")

    {:ok, _view, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "1 of 1 shown"
    refute html =~ "(max)"

    # Fill the ring: from here on the total is the most the log can hold, not
    # everything the sync wrote.
    for index <- 1..(Log.limit() + 5), do: Log.add(:info, "line #{index}")

    {:ok, _full_view, full} = live(conn, ~p"/admin/sync-log")

    assert full =~ "#{Log.limit()} of #{Log.limit()} (max) shown"
  end

  test "a reader can narrow the log to warnings and errors", %{conn: conn} do
    Log.add(:info, "page created: Budget")
    Log.add(:warn, "page failed: Broken")

    {:ok, view, html} = live(conn, ~p"/admin/sync-log")
    assert html =~ "page created: Budget"

    html = filter(view, "warn")

    refute html =~ "page created: Budget"
    assert html =~ "page failed: Broken"
  end

  test "the words narrow the lines already held and the ones that arrive", %{conn: conn} do
    Log.add(:info, "page created: Budget")
    Log.add(:info, "attachment pruned: diagram.svg")

    {:ok, view, html} = live(conn, ~p"/admin/sync-log")
    assert html =~ "attachment pruned: diagram.svg"

    html = filter(view, "all", "budget")

    refute html =~ "attachment pruned: diagram.svg"
    assert html =~ "page created: Budget"

    write(:info, "page renamed: Budget 2027")
    assert render(view) =~ "page renamed: Budget 2027"

    write(:info, "attachment pruned: another.svg")
    refute render(view) =~ "attachment pruned: another.svg"
  end

  # A job's row on the jobs page links here with the run it started, because the
  # log is one tail for every run and "what is this job doing?" is a question
  # about one of them.
  test "a run in the address narrows the log to that run's lines", %{conn: conn} do
    Log.add(:info, "pages listed for run 7", sync_run_id: 7)
    Log.add(:info, "details rendered for run 8", sync_run_id: 8)

    {:ok, view, html} = live(conn, ~p"/admin/sync-log?run=7")

    assert html =~ "pages listed for run 7"
    refute html =~ "details rendered for run 8"
    assert has_element?(view, "#sync-log-run-filter")

    # A line of another run arriving now is not this run's business either.
    write(:info, "another line for run 8", sync_run_id: 8)
    refute render(view) =~ "another line for run 8"

    write(:info, "another line for run 7", sync_run_id: 7)
    assert render(view) =~ "another line for run 7"
  end

  test "a run filter can be taken off again", %{conn: conn} do
    Log.add(:info, "pages listed for run 7", sync_run_id: 7)
    Log.add(:info, "details rendered for run 8", sync_run_id: 8)

    {:ok, view, _html} = live(conn, ~p"/admin/sync-log?run=7")

    assert has_element?(view, "#sync-log-run-filter a[href='/admin/sync-log']")

    # Without the parameter the page is what it always was: every run's lines.
    {:ok, _everything, html} = live(conn, ~p"/admin/sync-log")

    assert html =~ "details rendered for run 8"
    refute html =~ "sync-log-run-filter"
  end

  test "a filter decides what arrives after it is set", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    filter(view, "warn")

    write(:info, "page created: Budget")
    refute render(view) =~ "page created: Budget"

    write(:warn, "page failed: Broken")
    assert render(view) =~ "page failed: Broken"
  end

  test "two open pages filter for themselves", %{conn: conn} do
    Log.add(:info, "page created: Budget")
    Log.add(:warn, "page failed: Broken")

    {:ok, mine, _html} = live(conn, ~p"/admin/sync-log")
    {:ok, theirs, _html} = live(conn, ~p"/admin/sync-log")

    mine |> element("#sync-log-filter") |> render_change(%{"q" => "", "level" => "warn"})

    refute render(mine) =~ "page created: Budget"
    assert render(theirs) =~ "page created: Budget"
  end

  test "changing the filter puts a following reader on the newest line again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    filter(view, "warn")

    assert_push_event(view, "sync-log:new", _)
  end

  test "a paused reader is not moved when the filter changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    view |> element("#sync-log-follow") |> render_click()
    filter(view, "warn")

    refute_push_event(view, "sync-log:new", _)
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

    write(:info, "line while paused")

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

  test "an arrow takes a reader who scrolled away back to the newest line", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    # Following keeps the arrow out of the way: the newest line is already in
    # sight, so a button offering to go there would be noise.
    refute has_element?(view, "#sync-log-to-end")

    view |> render_hook("scrolled", %{"follow" => false})

    assert has_element?(view, "#sync-log-to-end[aria-label='Scroll to the newest line']")

    view |> element("#sync-log-to-end") |> render_click()

    refute has_element?(view, "#sync-log-to-end")
    assert has_element?(view, "#sync-log[data-follow=true]")
  end

  test "the lines a reader is looking at can be taken away in one click", %{conn: conn} do
    Log.add(:info, "page created: Budget")

    {:ok, view, _html} = live(conn, ~p"/admin/sync-log")

    assert has_element?(view, "#sync-log-copy[title*='Copy the lines shown']")
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

  defp write(level, message, details \\ []) do
    Log.add(level, message, details)
    # The log takes a line as a cast and broadcasts it to this page's process
    # before it answers a call, so reading the ring waits for both.
    Log.entries()
  end

  # The reader sets the level and the words in one form, and the page reports it
  # as one change.
  defp filter(view, level, words \\ "") do
    view |> element("#sync-log-filter") |> render_change(%{"q" => words, "level" => level})
  end
end
