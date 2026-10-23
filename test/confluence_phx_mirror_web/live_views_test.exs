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

    assert has_element?(view, "a[href='/spaces/ENG/pages/1002/Architecture+Overview']")
    assert has_element?(view, "mark", "Architecture")
  end

  test "a search hit is clickable across its whole card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=architecture")

    assert has_element?(
             view,
             "article[data-hit] a[data-hit-link][class~='after:inset-0'][href='/spaces/ENG/pages/1002/Architecture+Overview']"
           )
  end

  test "search LiveView supports boolean operators and quotes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search?q=rate+limit+NOT+roadmap")

    assert has_element?(view, "a[href='/spaces/ENG/pages/1004/Search+and+CQL']")
    refute has_element?(view, "a[href='/spaces/PROD/pages/2002/roadmap']")

    {:ok, phrase_view, _phrase} = live(conn, "/search?q=%22rate+limit%22")
    assert has_element?(phrase_view, "a[href='/spaces/ENG/pages/1004/Search+and+CQL']")
  end

  test "search LiveView narrows with structured filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?space=ENG&labels=architecture")

    assert has_element?(view, "a[href='/spaces/ENG/pages/1002/Architecture+Overview']")
    assert has_element?(view, "a", "Space: ENG")
    assert has_element?(view, "a", "Label: architecture")

    view
    |> element("#search-form")
    |> render_change(%{"search" => %{"q" => "pipeline"}})

    assert_patch(view, "/search?labels=architecture&q=pipeline&space=ENG")
    assert has_element?(view, "a[href='/spaces/ENG/pages/1002/Architecture+Overview']")
  end

  test "labels are free-form: a reader types one, then takes it off again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> element("#labels-filter > button") |> render_click()
    view |> form("#label-form", label: "Design") |> render_submit()

    assert_patch(view, "/search?labels=design")
    assert has_element?(view, "a", "Label: design")

    # The label menu stays open so several labels can be picked in one go.
    view |> element("#labels-filter button[phx-value-label='design']") |> render_click()

    assert_patch(view, "/search")
    refute has_element?(view, "a", "Label: design")
  end

  test "search LiveView explains when nothing matches", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/search?q=nothingmatchesthis")

    assert html =~ "No results"
  end

  test "admin overview shows freshness, runs and the way to the audit log", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin")

    assert html =~ "Overview"
    assert html =~ "Sync runs"
    assert html =~ "Latest activity"
    assert has_element?(view, "a[href='/admin/audit']")
    assert html =~ "40"
  end

  test "users page lists the assumed admin and creates tokens", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/users")

    admin = ConfluencePhxMirror.Accounts.get_user_by_email("admin@localhost")
    assert html =~ "Users"
    assert html =~ "admin@localhost"

    html =
      view
      |> element("#new-token-#{admin.id}", "Token name")
      |> render_submit(%{"user_id" => admin.id, "name" => "demo"})

    assert html =~ "New token"
  end
end
