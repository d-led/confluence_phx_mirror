defmodule ConfluencePhxMirrorWeb.PageStaleTest do
  @moduledoc """
  The notice a reader gets when the page under them is re-synced: offered with a
  reload, dismissible, and quiet when the copy they are reading is already the
  one the sync wrote.

  A page is a controller response, so the notice is an island `live_render/3`
  puts in the document; here it is mounted on its own with the page and the
  moment it was read, which is what the page hands it.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.PageUpdates

  @page_id 1002
  @path "/spaces/ENG/pages/1002/Architecture+Overview"
  @read_at "2026-10-25T10:00:00Z"
  @later "2026-10-25T10:00:05Z"

  setup %{conn: conn} do
    demo_snapshot!()

    {:ok, view, _html} =
      live_isolated(conn, ConfluencePhxMirrorWeb.PageStaleLive, session: session())

    %{view: view}
  end

  test "the page carries the notice", %{conn: conn} do
    html = conn |> get(@path) |> html_response(200)

    assert html =~ ~s(id="page-stale")
  end

  test "nothing is said while the page is the one the reader has", %{view: view} do
    refute has_element?(view, "#page-stale-notice")
  end

  test "a sync that writes the page offers a reload of it", %{view: view} do
    write(@later)

    assert has_element?(view, "#page-stale-notice")
    assert has_element?(view, "#page-stale-reload[href='#{@path}']", "Reload")
  end

  test "a write the reader already has is not news", %{view: view} do
    write(@read_at)
    refute has_element?(view, "#page-stale-notice")

    write("2026-10-25T09:59:59Z")
    refute has_element?(view, "#page-stale-notice")
  end

  test "dismissing puts it away, and the next write offers it again", %{view: view} do
    write(@later)
    assert has_element?(view, "#page-stale-notice")

    view |> element("#page-stale-dismiss") |> render_click()

    refute has_element?(view, "#page-stale-notice")

    write("2026-10-25T10:00:30Z")

    assert has_element?(view, "#page-stale-notice")
  end

  defp session do
    %{
      "stale_page_id" => @page_id,
      "stale_path" => @path,
      "stale_synced_at" => @read_at
    }
  end

  defp write(at) do
    Phoenix.PubSub.broadcast(
      ConfluencePhxMirror.PubSub,
      PageUpdates.topic(@page_id),
      {:page_synced, @page_id, at}
    )
  end
end
