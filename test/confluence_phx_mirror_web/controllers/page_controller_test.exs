defmodule ConfluencePhxMirrorWeb.PageControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "GET / renders the mirror home with spaces and freshness", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "read-only mirror"
    assert html =~ "Engineering Handbook"
    assert html =~ "Product Hub"
    assert html =~ "Search mirror"
    assert html =~ "Last sync"
  end

  test "GET /spaces/:key redirects to the space home page", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG")
    assert redirected_to(conn) == ~p"/spaces/ENG/pages/1000/engineering-handbook"
  end

  test "GET a page renders macro markup, labels and the original link", %{conn: conn} do
    html = conn |> get(~p"/spaces/ENG/pages/1002/architecture-overview") |> html_response(200)

    assert html =~ "Architecture Overview"
    assert html =~ "confluence-content"
    assert html =~ "View original"
    assert html =~ "/labels/architecture"
    assert html =~ ~s(href="/attachments/ENG/1002/9001/diagram.svg")
  end

  test "a stale slug redirects to the canonical page URL", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/1002/old-name")
    assert redirected_to(conn) == ~p"/spaces/ENG/pages/1002/architecture-overview"
  end

  test "unknown pages return 404", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/999999/missing")
    assert response(conn, 404) =~ "Not Found"
  end
end
