defmodule ConfluencePhxMirrorWeb.LiveViewsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "search LiveView searches every field by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=architecture")

    assert has_element?(view, "a[href='/spaces/ENG/pages/1002/architecture-overview']")
    assert has_element?(view, "mark", "Architecture")
  end

  test "search LiveView supports boolean operators and quotes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=rate+limit+NOT+roadmap")

    assert has_element?(view, "a[href='/spaces/ENG/pages/1004/search-and-cql']")
    refute has_element?(view, "a[href='/spaces/PROD/pages/2002/roadmap']")

    {:ok, phrase_view, _phrase} = live(conn, ~p"/search?q=%22rate+limit%22")
    assert has_element?(phrase_view, "a[href='/spaces/ENG/pages/1004/search-and-cql']")
  end

  test "search LiveView narrows with structured filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?space=ENG&label=architecture")

    assert has_element?(view, "a[href='/spaces/ENG/pages/1002/architecture-overview']")
    assert has_element?(view, "a", "Space: ENG")
    assert has_element?(view, "a", "Label: architecture")

    view
    |> form("#search-form",
      search: %{q: "pipeline", space: "ENG", label: "", type: "", updated: ""}
    )
    |> render_submit()

    assert_patch(view, "/search?q=pipeline&space=ENG")
    assert has_element?(view, "a[href='/spaces/ENG/pages/1002/architecture-overview']")
  end

  test "search LiveView explains when nothing matches", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/search?q=nothingmatchesthis")

    assert html =~ "No results"
  end

  test "admin dashboard shows freshness, runs and audit", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")

    assert html =~ "Mirror dashboard"
    assert html =~ "Sync runs"
    assert html =~ "Audit trail"
    assert html =~ "13"
  end

  test "users page lists the assumed admin and creates tokens", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/users")

    admin = ConfluencePhxMirror.Accounts.get_user_by_email("admin@localhost")
    assert html =~ "Users"
    assert html =~ "admin@localhost"

    html =
      view
      |> element("#new-token-#{admin.id}", "new token")
      |> render_submit(%{"user_id" => admin.id, "name" => "demo"})

    assert html =~ "New API token"
  end
end
