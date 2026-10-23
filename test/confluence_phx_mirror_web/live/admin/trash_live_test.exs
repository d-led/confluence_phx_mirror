defmodule ConfluencePhxMirrorWeb.Admin.TrashLiveTest do
  @moduledoc """
  The trash is the only place content is deleted for good, so it has to say what
  is in it, what goes with what, and ask twice before emptying.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.{Mirror, Repo, Trash}
  alias ConfluencePhxMirror.Mirror.{Page, Space}

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops-trash@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "an empty trash says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/trash")

    assert html =~ "The trash is empty"
  end

  test "a trashed space is listed with its pages and purged on request", %{conn: conn} do
    space = space_fixture(%{key: "GONE", name: "Gone Space"})
    page = page_fixture(space)

    assert Mirror.trash_space(space) == 1

    {:ok, view, html} = live(conn, ~p"/admin/trash")

    assert html =~ "GONE"
    assert html =~ "Gone Space"

    html = view |> element("#space-GONE button", "Delete for good") |> render_click()

    assert html =~ "GONE purged with 1 pages"
    assert Repo.get(Space, space.id) == nil
    assert Repo.get(Page, page.id) == nil
  end

  test "a trashed page is listed and purged on request", %{conn: conn} do
    space = space_fixture(%{key: "LIVE"})
    page = page_fixture(space, %{title: "Retired runbook"})

    Mirror.mark_missing_deleted(space, [])

    {:ok, view, html} = live(conn, ~p"/admin/trash")

    assert html =~ "Retired runbook"

    html = view |> element("#page-#{page.id} button", "Delete for good") |> render_click()

    assert html =~ "Retired runbook"
    assert Repo.get(Page, page.id) == nil
  end

  test "emptying the trash asks for a second click", %{conn: conn} do
    space = space_fixture(%{key: "BULK"})
    page_fixture(space)
    Mirror.trash_space(space)

    {:ok, view, html} = live(conn, ~p"/admin/trash")

    assert has_element?(view, "#space-BULK")
    refute has_element?(view, "#confirm-empty")
    assert html =~ "BULK"

    html = view |> element("#empty-trash") |> render_click()
    assert html =~ "1 spaces and 0 pages for good"

    html = view |> element("#confirm-empty") |> render_click()

    assert html =~ "Purged 1 spaces and 0 pages for good."
    assert Trash.spaces() == []
  end

  test "refuses to purge a space that came back", %{conn: conn} do
    space = space_fixture(%{key: "BACK"})
    Mirror.trash_space(space)

    {:ok, view, _html} = live(conn, ~p"/admin/trash")

    # A sync can bring the space back between the page loading and the click.
    Mirror.upsert_space(%{key: "BACK", name: "Back again"})

    html = view |> element("#space-BACK button", "Delete for good") |> render_click()

    assert html =~ "BACK is live again"
    assert Repo.get(Space, space.id)
  end
end
