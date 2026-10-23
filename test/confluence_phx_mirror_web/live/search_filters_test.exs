defmodule ConfluencePhxMirrorWeb.Live.SearchFiltersTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "the search page labels every active filter", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/search?q=pipeline&type=blogpost&updated=7d")

    assert html =~ "pipeline"
    assert html =~ "Type: blog posts"
    assert html =~ "Past 7 days"
  end

  test "an unusual filter value is still labelled", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/search?type=attachment&updated=14d")

    assert html =~ "Type: attachment"
    assert html =~ "Updated: 14d"
  end
end
