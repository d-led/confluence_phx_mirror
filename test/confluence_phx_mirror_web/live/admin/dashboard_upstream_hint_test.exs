defmodule ConfluencePhxMirrorWeb.Admin.DashboardUpstreamHintTest do
  @moduledoc """
  The one sentence the overview says about the site's own count.

  It used to subtract the last check's total from today's page count, so a
  mirror checked four days ago reported every page it had imported since — and
  every page of a space the check never settled — as "not in Confluence", while
  the review screen (`/admin/upstream`, which lists what is actually flagged)
  said there was nothing to review. The two screens read the same flag now.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.ReconcileRun

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops-hint@example.com", role: "admin"})
    {:ok, %{conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}}
  end

  test "a page the check did not name is not called missing", %{conn: conn} do
    space = space_fixture(%{key: "ENG", name: "Engineering"})
    page_fixture(space, %{title: "Mirrored after the check"})
    record_check(space, named: 2)

    {:ok, _view, html} = live(conn, ~p"/admin")

    refute html =~ "not in Confluence"
    assert html =~ "Confluence named 2"
  end

  test "a page the check flagged is the number the review screen lists", %{conn: conn} do
    space = space_fixture(%{key: "OPS", name: "Operations"})
    page_fixture(space, %{title: "Gone upstream"})
    record_check(space, named: 2)
    {1, 0} = Mirror.mark_absent(space, [])

    {:ok, _view, html} = live(conn, ~p"/admin")

    assert html =~ "1 not in Confluence"
    refute html =~ "Confluence named"
  end

  # A finished check that answered for `named` pages of `space`.
  defp record_check(space, named: named) do
    run = ReconcileRun.start(%{trigger: "a test"})

    ReconcileRun.observe(run, space, %{
      verdict: :listed,
      asked: 1,
      counted: false,
      named: named,
      marked: 0,
      cleared: 0,
      error: nil
    })

    ReconcileRun.finish(run, %{
      spaces: 1,
      agreed: 1,
      listed: [:a_listed_space],
      absent: 0,
      asked: 1
    })
  end
end
