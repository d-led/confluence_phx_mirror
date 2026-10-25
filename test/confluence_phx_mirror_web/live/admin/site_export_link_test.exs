defmodule ConfluencePhxMirrorWeb.Admin.SiteExportLinkTest do
  @moduledoc """
  The whole-site static export is offered where an administrator looks first:
  the dashboard, after the sync actions rather than between them, because it
  starts no sync — it reads what is already mirrored and asks the server for
  nothing but the bytes.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})
    space_fixture(%{key: "ENG", name: "Engineering"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the dashboard links to the whole-site download", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, ~s(a#export-site[href="/admin/export/site.zip"]), "Static site")
  end

  test "the link comes after both sync actions, not between them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    html = render(view)

    assert [{sync_at, _}, {space_at, _}, {export_at, _}] =
             Enum.map(["Sync now", "Sync one space", "Static site"], fn label ->
               :binary.match(html, label)
             end)

    assert sync_at < space_at and space_at < export_at
  end
end
