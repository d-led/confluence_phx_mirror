defmodule ConfluencePhxMirrorWeb.Live.SearchAdvancedTest do
  @moduledoc """
  Advanced search is a panel of widgets, and each of them narrows or widens the
  result list the way a reader expects — then everything ends up in the URL so a
  search can be shared.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "the panel is closed until it is asked for", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    refute has_element?(view, "#advanced-search")

    html = view |> element("#advanced-toggle") |> render_click()

    assert html =~ "Hide filters"
    assert has_element?(view, "#advanced-search")
  end

  test "the panel stays open while the reader types in one of its fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> open_panel()
    |> form("#advanced-search", search: %{"any" => "runbook"})
    |> render_change()

    assert_patch(view, "/search?any=runbook")
    assert has_element?(view, "#advanced-search")
    assert has_element?(view, "#advanced-search input[name='search[any]'][value='runbook']")
  end

  test "an exact phrase narrows the results to the sentence it searches for", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    html =
      view
      |> open_panel()
      |> form("#advanced-search", search: %{"phrase" => "token bucket"})
      |> render_change()

    assert_patch(view, "/search?phrase=token+bucket")
    assert html =~ "Phrase: token bucket"
  end

  test "a word to exclude removes the pages that mention it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=rate")

    view
    |> open_panel()
    |> form("#advanced-search", search: %{"none" => "pipeline"})
    |> render_change()

    assert_patch(view, "/search?none=pipeline&q=rate")
  end

  test "a space picked in the bar narrows the search to it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> element("#space-filter button[phx-value-space='ENG']")
    |> render_click()

    assert_patch(view, "/search?space=ENG")
    assert has_element?(view, "#space-filter", "Engineering Handbook")
  end

  defp open_panel(view) do
    view |> element("#advanced-toggle") |> render_click()
    view
  end

  test "a shared link opens the panel with its filters visible", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/search?spaces=ENG&creator=Jane+Doe&sort=newest")

    assert has_element?(view, "#advanced-search")
    assert html =~ "Spaces: ENG"
    assert html =~ "By: Jane Doe"
    assert html =~ "Sort: newest first"
  end

  test "sorting by recency is applied to the results", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=architecture")

    view |> element("#sort-form") |> render_change(%{"sort" => "oldest"})

    assert_patch(view, "/search?q=architecture&sort=oldest")
  end

  test "a shared link names the contributor it filters by", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?creator=Jane+Doe")

    assert has_element?(view, "#creator-filter > button", "Jane Doe")
    assert has_element?(view, "#creator-filter button[phx-value-creator='Jane Doe']")
  end
end
