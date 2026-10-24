defmodule ConfluencePhxMirrorWeb.ReaderPagePresenceTest do
  @moduledoc """
  Who is reading a page, seen the way a reader's browser sees it.

  A page is a plain controller response with a presence LiveView rendered into
  its rail, so there are two states to test — as the Testing LiveView course's
  "testing rendering" lesson puts it: the HTML that arrives before any socket
  exists, and the connected LiveView that keeps it current.

  Every assertion is scoped to the element it is about (`has_element?/3`), so a
  number appearing elsewhere on the page cannot make these pass.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Demo

  @page "/spaces/ENG/pages/1002/Architecture+Overview"

  setup do
    demo_snapshot!()
    :ok
  end

  test "the HTML that arrives first counts the reader who asked for it", %{conn: conn} do
    document = conn |> get(@page) |> html_response(200) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#page-presence-count") |> LazyHTML.text() |> String.trim() ==
             "1"

    assert document |> LazyHTML.query("#page-presence-readers li") |> Enum.count() == 1
  end

  test "a connected reader is on the page, named", %{conn: conn} do
    {:ok, view, _html} = open_page(conn, @page)

    assert has_element?(view, "#page-presence-count", "1")
    assert has_element?(view, "#page-presence-readers li")
  end

  test "a second reader arrives on the page the first already has open", %{conn: conn} do
    jane = user_fixture(%{display_name: "Jane"})
    sam = user_fixture(%{display_name: "Sam"})

    {:ok, jane_view, _html} =
      conn |> init_test_session(%{"user_id" => jane.id}) |> open_page(@page)

    {:ok, _sam_view, _html} =
      conn |> init_test_session(%{"user_id" => sam.id}) |> open_page(@page)

    assert has_element?(jane_view, "#page-presence-count", "2")
    assert has_element?(jane_view, "#page-presence-readers li", "Sam")
  end

  test "two tabs of one account are one reader", %{conn: conn} do
    jane = user_fixture(%{display_name: "Jane"})
    conn = init_test_session(conn, %{"user_id" => jane.id})

    {:ok, first_tab, _html} = open_page(conn, @page)
    {:ok, _second_tab, _html} = open_page(conn, @page)

    assert has_element?(first_tab, "#page-presence-count", "1")
  end

  test "a reader the restricted page is shared with is on it", %{conn: conn} do
    reader = in_group(Demo.page_readers())

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"user_id" => reader.id})
      |> open_page(restricted_page_path())

    assert has_element?(view, "#page-presence-count", "1")
    assert has_element?(view, "#page-presence-readers li")
  end

  # `live/2` follows a LiveView mounted by the router, and this page's presence
  # widgets are rendered into a controller response instead. The whole request
  # still runs — the session is signed by the endpoint, the LiveView mounts and
  # tracks — the test only has to say which LiveView on the page it is following.
  defp open_page(conn, path) do
    conn
    |> Plug.Conn.assign(:live_module, ConfluencePhxMirrorWeb.PagePresenceLive)
    |> live(path)
  end

  defp restricted_page_path do
    "/spaces/ENG/pages/#{Demo.restricted_page()}/#{Demo.restricted_page_slug()}"
  end

  defp in_group(group) do
    user = user_fixture()
    {:ok, user} = Accounts.update_groups(user, [group], {:system, "test"})
    user
  end
end
