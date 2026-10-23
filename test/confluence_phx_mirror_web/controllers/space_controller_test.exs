defmodule ConfluencePhxMirrorWeb.SpaceControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Mirror

  describe "the space icon" do
    test "serves the mirrored bytes with their media type and an ETag", %{conn: conn} do
      space = space_with_icon("<svg/>")

      conn = get(conn, ~p"/spaces/#{space.key}/icon")

      assert conn.status == 200
      assert response(conn, 200) == "<svg/>"
      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=86400"]
      assert [etag] = get_resp_header(conn, "etag")
      assert etag =~ ~r/^"[0-9a-f]{64}"$/
    end

    test "a space without an icon says so", %{conn: conn} do
      space = space_fixture(%{})

      assert conn |> get(~p"/spaces/#{space.key}/icon") |> response(404) ==
               "This space has no icon."
    end

    test "the directory and the overview show the icon", %{conn: conn} do
      space = space_with_icon("<svg/>")
      icon = ~s(src="/spaces/#{space.key}/icon")

      assert conn |> get(~p"/spaces") |> html_response(200) =~ icon
      assert conn |> get(~p"/spaces/#{space.key}/overview") |> html_response(200) =~ icon
    end

    test "the overview shows the space's categories beside its key", %{conn: conn} do
      space = space_fixture(%{name: "Design System", labels: ["teams", "design"]})

      html = conn |> get(~p"/spaces/#{space.key}/overview") |> html_response(200)

      assert html =~ ~s(class="badge badge-outline badge-sm">teams</span>)
      assert html =~ ~s(class="badge badge-outline badge-sm">design</span>)
    end
  end

  describe "the space overview" do
    test "shows the space home, its top-level pages and the section tabs", %{conn: conn} do
      {space, home} = space_with_home("Engineering Handbook")
      page_fixture(space, %{title: "Architecture Overview", slug: "architecture-overview"})

      html = conn |> get(~p"/spaces/#{space.key}/overview") |> html_response(200)

      assert html =~ home.title
      assert html =~ "Top-level pages"
      assert html =~ "Architecture Overview"
      assert html =~ ~s(href="/spaces/#{space.key}/pages")
      assert html =~ ~s(href="/spaces/#{space.key}/blog")
      assert html =~ ~s(href="/spaces/#{space.key}/attachments")
    end

    test "shows the space's blog posts and labels", %{conn: conn} do
      space = space_fixture(%{name: "Product Hub"})
      page_fixture(space, %{title: "Release 2.0", type: "blogpost", slug: "release-2-0"})

      labelled = page_fixture(space, %{title: "Roadmap", slug: "roadmap"})
      {:ok, _labels} = Mirror.replace_labels(labelled, ["release"])

      html = conn |> get(~p"/spaces/#{space.key}/overview") |> html_response(200)

      assert html =~ "Release 2.0"
      assert html =~ ~s(href="/labels/release")
    end

    test "a space link redirects to the space home page", %{conn: conn} do
      {space, home} = space_with_home("Engineering Handbook")

      conn = get(conn, ~p"/spaces/#{space.key}")

      assert redirected_to(conn) ==
               ~p"/spaces/#{space.key}/pages/#{home.confluence_id}/space-home"
    end
  end

  test "an unknown space is a 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/overview") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end

  test "an unknown space has no icon either", %{conn: conn} do
    assert conn |> get(~p"/spaces/NOPE/icon") |> response(404) == "This space has no icon."
  end

  # A space whose icon the sync mirrored, the way a linked sync leaves it.
  defp space_with_icon(bytes) do
    space = space_fixture(%{name: "Engineering Handbook"})
    blob_key = Key.space_icon(space.key, "image/svg+xml")
    {:ok, ^blob_key} = Store.put(blob_key, bytes)

    {:ok, space} =
      Mirror.upsert_space(%{
        key: space.key,
        name: space.name,
        icon_blob_key: blob_key,
        icon_media_type: "image/svg+xml",
        icon_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      })

    space
  end

  # A space whose home page is already mirrored, the way a sync leaves it.
  defp space_with_home(name) do
    space = space_fixture(%{name: name})
    home = page_fixture(space, %{title: "Space home", slug: "space-home"})

    {:ok, space} =
      Mirror.upsert_space(%{
        key: space.key,
        name: name,
        homepage_confluence_id: home.confluence_id
      })

    {space, home}
  end
end
