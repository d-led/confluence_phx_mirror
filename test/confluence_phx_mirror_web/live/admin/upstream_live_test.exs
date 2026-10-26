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

  alias ConfluencePhxMirror.{Jobs, Mirror, Trash}
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

  test "a clean check says what it compared, not only what it concluded", %{
    conn: conn,
    space: space
  } do
    # A pass of two spaces on a source that cannot report totals: the point is
    # that the screen shows the comparison it made, so that "found everything"
    # can be believed or doubted on evidence.
    run = ReconcileRun.start(%{trigger: "a test"})

    for {key, pages} <- [{"ENG", 934}, {"OPS", 66}] do
      ReconcileRun.observe(run, space_fixture(%{key: key}), %{
        verdict: :listed,
        asked: 1,
        counted: false,
        named: pages,
        marked: 0,
        cleared: 0,
        error: nil
      })
    end

    ReconcileRun.finish(run, %{spaces: 2, agreed: 0, listed: ["ENG", "OPS"], absent: 0, asked: 2})

    {:ok, view, html} = live(conn, ~p"/admin/upstream")

    assert html =~ "The site named 1000 ids in them"

    assert view |> element("#upstream-no-counts") |> render() =~
             "reports no per-space total, so every space had to be listed in full"

    assert space.id
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

    assert view |> element("#absent-total") |> render() =~ "1 page in 1 space"

    html = view |> element("#trash-#{absent.id}") |> render_click()

    assert html =~ "moved to the trash"
    assert Mirror.find_page(1002) == {:error, :not_found}
    assert [{trashed, ^space}] = Trash.pages()
    assert trashed.deleted_reason == "vanished"
    refute has_element?(view, "#absent-#{absent.id}")
  end

  test "the count says how much is waiting, and goes down as pages leave", %{
    conn: conn,
    space: space,
    absent: absent
  } do
    mark_absent(space, absent)
    other = page_fixture(space, %{confluence_id: 1004, title: "Also Gone"})
    mark_absent(space, other)

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    assert view |> element("#absent-total") |> render() =~ "2 pages in 1 space"

    view |> element("#trash-#{absent.id}") |> render_click()

    assert view |> element("#absent-total") |> render() =~ "1 page in 1 space"
  end

  test "facts appear as the pass records them, without a reload", %{conn: conn, space: space} do
    run = ReconcileRun.start(%{trigger: "a test"})

    {:ok, view, html} = live(conn, ~p"/admin/upstream")

    assert html =~ "What this check has settled"
    refute has_element?(view, "#fact-ENG")

    # What `Reconcile` does after it has counted, listed and marked a space.
    ReconcileRun.observe(run, space, %{
      verdict: :listed,
      asked: 1,
      counted: false,
      named: 934,
      marked: 3,
      cleared: 0,
      error: nil
    })

    assert has_element?(view, "#fact-ENG")
    assert view |> element("#upstream-facts") |> render() =~ "named its ids"
  end

  test "the progress list names the newest facts and counts the rest", %{conn: conn} do
    run = ReconcileRun.start(%{trigger: "a test"})

    for n <- 1..55 do
      ReconcileRun.observe(run, space_fixture(%{key: "S#{n}"}), %{
        verdict: :agreed,
        asked: 1,
        counted: true,
        named: 0,
        marked: 0,
        cleared: 0,
        error: nil
      })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    assert view |> element("#upstream-facts") |> render() =~ "Showing the newest 50 of 55"
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

  test "a check Oban still holds is reported as queued or running", %{conn: conn} do
    {:ok, _job} = ReconcileWorker.new(%{"trigger" => "a test"}) |> Oban.insert()

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    assert view |> element("#upstream-in-flight") |> render() =~ "queued or running"
    refute has_element?(view, "#upstream-unchecked")
  end

  test "a cancelled check is history, not work in flight", %{conn: conn} do
    {:ok, job} = ReconcileWorker.new(%{"trigger" => "a test"}) |> Oban.insert()
    {:ok, _cancelled} = Jobs.cancel(job.id, {:system, "a test"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    refute has_element?(view, "#upstream-in-flight")
  end

  test "a pass that stopped with no job left is not called a running check", %{conn: conn} do
    # What a killed job leaves: a pass with no outcome that Oban no longer holds.
    # Saying "a check is running" about it would describe a process that is gone.
    ReconcileRun.start(%{trigger: "a pass that was killed"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    assert view |> element("#upstream-interrupted") |> render() =~ "did not finish"
    refute has_element?(view, "#upstream-in-flight")
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
