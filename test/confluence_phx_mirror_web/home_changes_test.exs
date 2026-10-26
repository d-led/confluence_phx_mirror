defmodule ConfluencePhxMirrorWeb.HomeChangesTest do
  @moduledoc """
  The home page answers "what changed?" — a window of the newest changes, each
  saying what happened, who did it and where, with the whole feed one click
  away. It never ships the feed itself.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  test "says what happened to each change, and who", %{conn: conn} do
    space = space_fixture(%{key: "CHG", name: "Changes"})

    page_fixture(space, %{
      title: "Brand new",
      confluence_id: 93_001,
      version_number: 1,
      author_name: "Ada",
      external_updated_at: ~U[2026-10-23 10:00:00Z]
    })

    page_fixture(space, %{
      title: "Edited twice",
      confluence_id: 93_002,
      version_number: 3,
      author_name: "Grace",
      external_updated_at: ~U[2026-10-23 11:00:00Z]
    })

    html = conn |> get(~p"/") |> html_response(200)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "h2") |> LazyHTML.text() =~ "Latest changes"
    assert html =~ "See all changes"

    rows = LazyHTML.query(document, "#latest-changes li") |> LazyHTML.text()
    assert rows =~ "Brand new"
    assert rows =~ "created"
    assert rows =~ "Edited twice"
    assert rows =~ "updated"
    assert rows =~ "Changes · Ada"
    assert rows =~ "Changes · Grace"
  end

  test "shows a window, not the feed", %{conn: conn} do
    space = space_fixture(%{key: "MANY"})

    for n <- 1..12 do
      page_fixture(space, %{
        title: "Change #{n}",
        confluence_id: 93_100 + n,
        external_updated_at: DateTime.add(~U[2026-10-01 00:00:00Z], n, :hour)
      })
    end

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(document, "#latest-changes li")) == 8
    assert LazyHTML.query(document, "#latest-changes li") |> LazyHTML.text() =~ "Change 12"
  end
end
