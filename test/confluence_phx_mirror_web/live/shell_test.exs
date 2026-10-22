defmodule ConfluencePhxMirrorWeb.ShellTest do
  @moduledoc """
  The shell around every page: the navigation a reader gets on a phone as well as
  on a laptop, and the shortcuts that make it usable without a mouse.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  describe "the space navigation" do
    test "is a sidebar the reader can collapse, with a button that says so", %{conn: conn} do
      space_fixture(%{key: "ENG", name: "Engineering Handbook"})

      {:ok, view, _html} = live(conn, ~p"/spaces")

      assert has_element?(view, "button[data-sidebar-toggle][aria-controls='mirror-sidebar']")
      assert has_element?(view, "#mirror-sidebar a[href='/spaces/ENG']")
    end

    test "shows the page tree inside a space", %{conn: conn} do
      space = space_fixture(%{key: "ENG", name: "Engineering Handbook"})
      page = page_fixture(space, %{title: "Architecture Overview"})

      {:ok, view, _html} = live(conn, ~p"/spaces/ENG/pages")

      assert has_element?(
               view,
               "#mirror-sidebar a[href='/spaces/ENG/pages/#{page.confluence_id}/#{page.slug}']"
             )
    end
  end

  describe "getting to the content" do
    test "a skip link jumps past the header into a focusable main region", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ ~s(href="#mirror-content")
      assert html =~ ~s(id="mirror-content")
    end
  end
end
