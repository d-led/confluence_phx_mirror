defmodule ConfluencePhxMirrorWeb.Admin.RefreshCadenceTest do
  @moduledoc """
  The overview carries two kinds of number, so it is read at two speeds.

  What a run is doing moves by the second and an operator sits and watches it;
  the totals, the run table and the resource figures change slowly, and they are
  re-read on a longer, configurable interval
  (`CM_ADMIN_STATS_REFRESH_SECONDS`, 30 by default). These hold both halves:
  the slow tick really does re-read the mirror, and the fast tick does not.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.QueryCounter

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the totals catch up when the slow tick fires", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    refute render(view) =~ "Freshly mirrored"

    space = space_fixture(%{name: "Engineering"})
    page_fixture(space, %{title: "Freshly mirrored", slug: "Freshly+mirrored"})

    send(view.pid, :stats)

    assert render(view) =~ "Freshly mirrored"
  end

  test "the five-second tick asks about the run, not the totals", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    # Warm whatever the message itself needs, then count the tick alone.
    send(view.pid, :progress)
    render(view)

    queries =
      QueryCounter.count(fn ->
        send(view.pid, :progress)
        render(view)
      end)

    assert queries <= 3, "a progress tick issued #{queries} queries"
  end
end
