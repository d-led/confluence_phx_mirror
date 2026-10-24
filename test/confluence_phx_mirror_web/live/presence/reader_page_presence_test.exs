defmodule ConfluencePhxMirrorWeb.ReaderPagePresenceTest do
  @moduledoc """
  Who is reading a page, seen the way a reader's browser sees it.

  A page is a plain controller response with a presence LiveView rendered into
  its rail — and the same widget again in its metadata row, as the count a
  narrow screen keeps when the rail is hidden — so there are two states to
  test, as the Testing LiveView course's "testing rendering" lesson puts it:
  the HTML that arrives before any socket exists, and the connected LiveView
  that keeps it current.

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

  # The rail is hidden on a narrow screen, so the page's metadata row carries
  # the count too — an icon and a number after the sync stamp, no names.
  test "the narrow layout's count arrives with the page's metadata", %{conn: conn} do
    document = conn |> get(@page) |> html_response(200) |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("#page-presence-compact")
           |> LazyHTML.text()
           |> String.trim() == "1"
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

  # A page renders both widgets for one reader, so only the rail tracks: an
  # anonymous reader is keyed by their connection, and a second process
  # tracking them would be a second reader.
  test "the narrow layout's count is the rail's, not one more", %{conn: conn} do
    {:ok, rail, _html} = open_page(conn, @page)
    {:ok, badge, _html} = open_badge(conn, @page)

    assert has_element?(rail, "#page-presence-count", "1")
    assert has_element?(badge, "#page-presence-compact-count", "1")
  end

  test "the narrow layout's count follows the readers arriving", %{conn: conn} do
    jane = user_fixture(%{display_name: "Jane"})
    sam = user_fixture(%{display_name: "Sam"})

    {:ok, _rail, _html} =
      conn |> init_test_session(%{"user_id" => jane.id}) |> open_page(@page)

    {:ok, badge, _html} =
      conn |> init_test_session(%{"user_id" => sam.id}) |> open_badge(@page)

    assert has_element?(badge, "#page-presence-compact-count", "2")
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

  # `live/2` follows the first LiveView in the document, and a page now renders
  # several: the shell's space switcher in the header comes before the rail's
  # presence widget. What this file is about is the presence widget, so it is
  # mounted on its own with the page it would have been handed; the request
  # itself is covered by "the HTML that arrives first counts the reader who
  # asked for it".
  defp open_page(conn, path), do: mount_presence(conn, path, %{})

  defp open_badge(conn, path),
    do: mount_presence(conn, path, %{"presence_variant" => "compact"})

  defp mount_presence(conn, path, extra) do
    session =
      conn.private[:plug_session]
      |> Kernel.||(%{})
      |> Map.take(["user_id"])
      |> Map.merge(extra)
      |> Map.put("presence_page", page_number(path))

    live_isolated(conn, ConfluencePhxMirrorWeb.PagePresenceLive, session: session)
  end

  defp page_number(path), do: path |> String.split("/") |> Enum.at(4)

  defp restricted_page_path do
    "/spaces/ENG/pages/#{Demo.restricted_page()}/#{Demo.restricted_page_slug()}"
  end

  defp in_group(group) do
    user = user_fixture()
    {:ok, user} = Accounts.update_groups(user, [group], {:system, "test"})
    user
  end
end
