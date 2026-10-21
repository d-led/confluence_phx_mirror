defmodule ConfluencePhxMirrorWeb.SpaceControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  describe "the space directory" do
    test "lists every space with its content counts", %{conn: conn} do
      html = conn |> get(~p"/spaces") |> html_response(200)

      assert html =~ "Engineering Handbook"
      assert html =~ "Product Hub"
      assert html =~ ~s(href="/spaces/ENG")
      assert html =~ ~s(href="/spaces/PROD")
      assert html =~ "blog posts"
    end
  end

  describe "the space overview" do
    test "shows the space home, top-level pages and the section tabs", %{conn: conn} do
      html = conn |> get(~p"/spaces/ENG/overview") |> html_response(200)

      assert html =~ "Space home"
      assert html =~ "Top-level pages"
      assert html =~ ~s(href="/spaces/ENG/pages")
      assert html =~ ~s(href="/spaces/ENG/blog")
      assert html =~ ~s(href="/spaces/ENG/attachments")
    end

    test "shows the blog and labels of the space", %{conn: conn} do
      html = conn |> get(~p"/spaces/PROD/overview") |> html_response(200)

      assert html =~ "Release 2.0"
      assert html =~ ~s(href="/labels/release")
    end

    test "a space link keeps redirecting to its home page", %{conn: conn} do
      conn = get(conn, ~p"/spaces/ENG")

      assert redirected_to(conn) == ~p"/spaces/ENG/pages/1000/engineering-handbook"
    end
  end

  describe "the pages catalog" do
    test "lists current and archived pages with their status", %{conn: conn} do
      html = conn |> get(~p"/spaces/ENG/pages") |> html_response(200)

      assert html =~ "Architecture Overview"
      assert html =~ "Deprecated Setup"
      assert html =~ "archived"
      refute html =~ "Release 2.0"
    end
  end

  describe "the blog catalog" do
    test "lists the space's posts", %{conn: conn} do
      html = conn |> get(~p"/spaces/PROD/blog") |> html_response(200)

      assert html =~ "Release 2.0"
      assert html =~ ~s(href="/spaces/PROD/blog/2001/release-2-0")
    end

    test "does not list another space's posts", %{conn: conn} do
      html = conn |> get(~p"/spaces/ENG/blog") |> html_response(200)

      refute html =~ "Release 2.0"
    end
  end

  describe "the attachment catalog" do
    test "lists files with their download links", %{conn: conn} do
      html = conn |> get(~p"/spaces/ENG/attachments") |> html_response(200)

      assert html =~ "architecture.csv"
      assert html =~ "/attachments/ENG/1002/9002/architecture.csv"
      assert html =~ "Architecture Overview"
    end
  end

  test "an unknown space is a 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/overview") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end
end
