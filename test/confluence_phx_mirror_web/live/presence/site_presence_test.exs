defmodule ConfluencePhxMirrorWeb.SitePresenceTest do
  @moduledoc """
  The footer's "Users online", from a reader's side.

  The footer belongs to every page, so it is the same LiveView in two positions:
  a root LiveView on the controller-rendered pages, and a child of the page's
  LiveView on the LiveView-rendered ones. A child is what `find_live_child/2`
  is for — the Testing LiveView course's way of reaching a LiveView nested in
  another.

  The site topic is shared by every test running at once, so the counts here are
  read as "more than before" rather than as absolute numbers.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  @page "/spaces/ENG/pages/1002/Architecture+Overview"
  @live_page "/spaces"

  setup do
    demo_snapshot!()
    :ok
  end

  test "a plain page's footer counts the reader who asked for it", %{conn: conn} do
    document = conn |> get(@page) |> html_response(200) |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("#site-presence-count")
           |> LazyHTML.text()
           |> String.trim()
           |> String.to_integer() >= 1
  end

  test "a LiveView page's footer counts its reader", %{conn: conn} do
    {:ok, view, _html} = live(conn, @live_page)
    footer = find_live_child(view, "site-presence")

    assert has_element?(footer, "#site-presence-count")
    assert footer |> element("#site-presence-count") |> render() |> count_in() >= 1
  end

  test "another account raises the footer's count", %{conn: conn} do
    jane = user_fixture()
    sam = user_fixture()

    {:ok, jane_view, _html} =
      conn |> init_test_session(%{"user_id" => jane.id}) |> live(@live_page)

    footer = find_live_child(jane_view, "site-presence")
    before = footer |> element("#site-presence-count") |> render() |> count_in()

    {:ok, _sam_view, _html} =
      conn |> init_test_session(%{"user_id" => sam.id}) |> live(@live_page)

    assert footer |> element("#site-presence-count") |> render() |> count_in() > before
  end

  # The rendered number, not the page's text: "Users online:" also appears in
  # nothing else, but a number somewhere else on the page must not satisfy this.
  defp count_in(rendered) do
    rendered
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
    |> String.to_integer()
  end
end
