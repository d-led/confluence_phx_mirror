defmodule ConfluencePhxMirrorWeb.SpaceControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror

  describe "the space overview" do
    test "shows the space home, its top-level pages and the section tabs", %{conn: conn} do
      {space, home} = space_with_home("ENG", "Engineering Handbook")
      page_fixture(space, %{title: "Architecture Overview", slug: "architecture-overview"})

      html = conn |> get(~p"/spaces/ENG/overview") |> html_response(200)

      assert html =~ home.title
      assert html =~ "Top-level pages"
      assert html =~ "Architecture Overview"
      assert html =~ ~s(href="/spaces/ENG/pages")
      assert html =~ ~s(href="/spaces/ENG/blog")
      assert html =~ ~s(href="/spaces/ENG/attachments")
    end

    test "shows the space's blog posts and labels", %{conn: conn} do
      space = space_fixture(%{key: "PROD", name: "Product Hub"})
      page_fixture(space, %{title: "Release 2.0", type: "blogpost", slug: "release-2-0"})

      labelled = page_fixture(space, %{title: "Roadmap", slug: "roadmap"})
      {:ok, _labels} = Mirror.replace_labels(labelled, ["release"])

      html = conn |> get(~p"/spaces/PROD/overview") |> html_response(200)

      assert html =~ "Release 2.0"
      assert html =~ ~s(href="/labels/release")
    end

    test "a space link redirects to the space home page", %{conn: conn} do
      {_space, home} = space_with_home("ENG", "Engineering Handbook")

      conn = get(conn, ~p"/spaces/ENG")

      assert redirected_to(conn) == ~p"/spaces/ENG/pages/#{home.confluence_id}/space-home"
    end
  end

  test "an unknown space is a 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/overview") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end

  # A space whose home page is already mirrored, the way a sync leaves it.
  defp space_with_home(key, name) do
    space = space_fixture(%{key: key, name: name})
    home = page_fixture(space, %{title: "Space home", slug: "space-home"})

    {:ok, space} =
      Mirror.upsert_space(%{key: key, name: name, homepage_confluence_id: home.confluence_id})

    {space, home}
  end
end
