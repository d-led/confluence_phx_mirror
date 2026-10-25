defmodule ConfluencePhxMirrorWeb.Admin.FullRereadTest do
  @moduledoc """
  "Re-read everything" is the heaviest thing an administrator can ask for: every
  page and attachment fetched and rendered again, changed or not. So it is not
  one of the everyday actions in the header, it says what it costs where it
  stands, and it asks before it queues.

  What it queues is a sweep — one sync per space — rather than a single
  site-sized run, because that run is what a 1 GB node cannot hold in memory.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false
  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Sync.SweepWorker

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "it stands apart from the everyday actions, in a sentence that says what it spends",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    document = view |> render() |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "header #full-sync")),
           "a re-read does not belong in the row that holds Sync now"

    note = LazyHTML.query(document, "#full-reread")
    assert LazyHTML.text(note) =~ "every page and attachment, changed or not"
    assert LazyHTML.text(note) =~ "hours on a large site"

    # The native confirm is what stops the finger: it has to name the cost, not
    # ask "are you sure?".
    button = view |> element("#full-sync") |> render()
    assert button =~ "data-confirm"
    assert button =~ "runs for hours"
  end

  test "once confirmed, it queues a sweep that re-reads rather than a diff", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#full-sync") |> render_click()

    assert render(view) =~ "Full re-read queued"

    assert [job] = all_enqueued(worker: SweepWorker)
    assert job.args["trigger"] =~ "re-reading everything"
    # A diff is the schedule's job; a re-read must not be queued as one.
    assert all_enqueued(worker: ConfluencePhxMirror.Sync.SnapshotWorker) == []
  end
end
