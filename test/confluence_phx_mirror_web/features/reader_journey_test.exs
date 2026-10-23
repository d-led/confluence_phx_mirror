defmodule ConfluencePhxMirrorWeb.Features.ReaderJourneyTest do
  use ConfluencePhxMirrorWeb.FeatureCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "a reader walks from the space directory into a page", %{conn: conn} do
    conn
    |> visit(~p"/spaces")
    |> within("main", &click_link(&1, "Engineering Handbook"))
    |> assert_path("/spaces/ENG/pages/1000/Engineering+Handbook")
    |> assert_has("h1", "Engineering Handbook")
    |> within("#page-tree", &click_link(&1, "Getting Started"))
    |> assert_path("/spaces/ENG/pages/1001/Getting+Started")
    # The sidebar follows the reader: the page's children are now in reach.
    |> within("#page-tree", &click_link(&1, "Architecture Overview"))
    |> assert_path("/spaces/ENG/pages/1002/Architecture+Overview")
    |> assert_has("h1", "Architecture Overview")
    |> assert_has("a", "View original")
  end

  test "a reader searches from the home page and opens a result", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> fill_in("Search the mirror", with: "rate limit")
    |> click_button("Search")
    |> assert_path(~p"/search", query_params: %{q: "rate limit"})
    |> assert_has("a", "Search and CQL")
    |> click_link("Search and CQL")
    |> assert_path("/spaces/ENG/pages/1004/Search+and+CQL")
    |> assert_has("h1", "Search and CQL")
  end

  test "a reader's variant follows them to the next page", %{conn: conn} do
    conn
    |> visit(~p"/spaces")
    |> click_link("Dark")
    |> assert_has("html[data-scheme='dark']")
    |> reload_page()
    |> assert_has("html[data-scheme='dark']")
  end

  test "a reader jumps from a page label to everything carrying it", %{conn: conn} do
    conn
    |> visit("/spaces/ENG/pages/1002/Architecture+Overview")
    |> click_link("a.badge[href='/labels/architecture']", "architecture")
    |> assert_path(~p"/labels/architecture")
    |> assert_has("h1", "architecture")
    |> assert_has("a", "Architecture Overview")
  end
end
