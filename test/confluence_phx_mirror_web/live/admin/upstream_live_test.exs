defmodule ConfluencePhxMirrorWeb.Admin.UpstreamLiveTest do
  @moduledoc """
  The review screen: what the site did not name, and what happens when somebody
  decides about it.

  The screen must never trash anything by itself, must say the same page only
  once, and must let an operator take one page or a whole space.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.{Mirror, Trash}
  alias ConfluencePhxMirror.Sync.{ReconcileRun, ReconcileWorker, TrashAbsentWorker}

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops-upstream@example.com", role: "admin"})
    space = space_fixture(%{key: "ENG", name: "Engineering"})
    absent = page_fixture(space, %{confluence_id: 1002, title: "Vanished Page"})

    {:ok,
     %{
       conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id}),
       space: space,
       absent: absent
     }}
  end

  test "an unchecked mirror says so instead of claiming there is nothing to review", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/admin/upstream")

    assert html =~ "Nobody has checked this mirror against the site yet"
    refute html =~ "found every page the site lists"
  end

  test "after a check that found nothing, it cites the check rather than promising", %{conn: conn} do
    record_check(%{spaces: 12, agreed: 12, listed: 0, absent: 0, asked: 12})

    {:ok, _view, html} = live(conn, ~p"/admin/upstream")

    assert html =~ "compared 12 spaces and found every page the site lists"
    assert html =~ "That is a statement about that moment, not about now"
  end

  test "an absent page is listed with its space and when it was noticed", %{
    conn: conn,
    space: space,
    absent: absent
  } do
    mark_absent(space, absent)

    {:ok, view, html} = live(conn, ~p"/admin/upstream")

    assert html =~ "Vanished Page"
    assert html =~ "ENG"
    assert has_element?(view, "#absent-#{absent.id} time[data-local-time]")
    assert has_element?(view, "#space-ENG", "Trash all 1")
  end

  test "listing the page does not trash it", %{conn: conn, space: space, absent: absent} do
    mark_absent(space, absent)

    {:ok, _view, _html} = live(conn, ~p"/admin/upstream")

    assert {:ok, still_live} = Mirror.find_page(1002)
    assert still_live.deleted_at == nil
    assert Trash.pages() == []
  end

  test "an administrator trashes one page, and it moves to the trash", %{
    conn: conn,
    space: space,
    absent: absent
  } do
    mark_absent(space, absent)

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    html = view |> element("#trash-#{absent.id}") |> render_click()

    assert html =~ "moved to the trash"
    assert Mirror.find_page(1002) == {:error, :not_found}
    assert [{trashed, ^space}] = Trash.pages()
    assert trashed.deleted_reason == "vanished"
    refute has_element?(view, "#absent-#{absent.id}")
  end

  test "a whole space's absent pages are queued as a job, not done in the click", %{
    conn: conn,
    space: space,
    absent: absent
  } do
    mark_absent(space, absent)
    other = page_fixture(space, %{confluence_id: 1003, title: "Also Gone"})
    mark_absent(space, other)

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    html = view |> element("#space-ENG button", "Trash all 2") |> render_click()

    assert html =~ "Trashing 2 pages of ENG in the background"
    assert_enqueued(worker: TrashAbsentWorker)

    # The job has not run yet, so nothing has moved and the review still shows it.
    assert Mirror.count_absent() == 2
    assert Trash.pages() == []
    assert has_element?(view, "#absent-#{absent.id}")
  end

  test "asking for a verify pass queues the job and reads nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    html = view |> element("#check-upstream") |> render_click()

    assert html =~ "A verify pass is queued"
    assert_enqueued(worker: ReconcileWorker)
  end

  test "a second click while one is queued says so instead of queueing another", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    view |> element("#check-upstream") |> render_click()
    html = view |> element("#check-upstream") |> render_click()

    assert html =~ "already queued or running"
    assert length(all_enqueued(worker: ReconcileWorker)) == 1
  end

  test "a pass in flight is an answer about now, not 'nobody has checked'", %{conn: conn} do
    # An interrupted pass leaves its settled spaces recorded and its row open.
    interrupted = ReconcileRun.start(%{trigger: "a test"})

    ReconcileRun.observe(interrupted, Mirror.get_space_by_key("ENG"), %{
      verdict: :agreed,
      asked: 1,
      marked: 0,
      cleared: 0,
      error: nil
    })

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    assert view |> element("#upstream-running") |> render() =~ "settled 1 spaces"
    refute has_element?(view, "#upstream-unchecked")
  end

  # The verify pass is what sets this, so the test sets it the same way rather
  # than reaching into the page row.
  defp mark_absent(space, page) do
    Mirror.mark_absent(space, [])
    record_check(%{spaces: 1, agreed: 0, listed: 1, absent: 1, asked: 2})
    {:ok, marked} = Mirror.find_page(page.confluence_id)
    marked
  end

  # The record counts the spaces that needed a listing, so the helper takes the
  # count and hands `finish/2` the list the real pass would have.
  defp record_check(report) do
    run = ReconcileRun.start(%{trigger: "a test"})

    report
    |> Map.update!(:listed, fn count -> List.duplicate(:a_listed_space, count) end)
    |> Map.merge(%{failed: [], empty: []})
    |> then(&ReconcileRun.finish(run, &1))
  end
end
