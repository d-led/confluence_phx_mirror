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
  alias ConfluencePhxMirror.Sync.ReconcileWorker

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

  test "a mirror the site agrees with says there is nothing to review", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/upstream")

    assert html =~ "Every page the mirror holds is one Confluence still lists"
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

  test "a whole space's absent pages go together", %{conn: conn, space: space, absent: absent} do
    mark_absent(space, absent)
    other = page_fixture(space, %{confluence_id: 1003, title: "Also Gone"})
    mark_absent(space, other)

    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    html = view |> element("#space-ENG button", "Trash all 2") |> render_click()

    assert html =~ "2 pages of ENG moved to the trash"
    assert Mirror.count_absent() == 0
    assert length(Trash.pages()) == 2
  end

  test "asking for a verify pass queues the job and reads nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/upstream")

    html = view |> element("#check-upstream") |> render_click()

    assert html =~ "A verify pass is queued"
    assert_enqueued(worker: ReconcileWorker)
  end

  # The verify pass is what sets this, so the test sets it the same way rather
  # than reaching into the page row.
  defp mark_absent(space, page) do
    Mirror.mark_absent(space, [])
    {:ok, marked} = Mirror.find_page(page.confluence_id)
    marked
  end
end
