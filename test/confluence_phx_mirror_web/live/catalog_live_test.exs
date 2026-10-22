defmodule ConfluencePhxMirrorWeb.CatalogLiveTest do
  @moduledoc """
  What a reader gets from a catalog page: a list they can narrow by typing, one
  page at a time, and the same behaviour on every catalog.

  Each test builds the handful of rows it talks about, so the suite stays quick
  and a test fails only for the behaviour it names.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror

  describe "the space directory" do
    test "lists the spaces and narrows as the reader types", %{conn: conn} do
      handbook = space_fixture(%{name: "Engineering Handbook"})
      product = space_fixture(%{name: "Product Hub"})

      {:ok, view, _html} = live(conn, ~p"/spaces")

      assert has_element?(view, "#catalog-results a[href='/spaces/#{handbook.key}']")
      assert has_element?(view, "#catalog-results a[href='/spaces/#{product.key}']")

      filter(view, "engineering")

      assert has_element?(view, "#catalog-results a[href='/spaces/#{handbook.key}']")
      refute has_element?(view, "#catalog-results a[href='/spaces/#{product.key}']")
    end

    test "needs every word the reader types", %{conn: conn} do
      space_fixture(%{name: "Engineering Handbook"})
      space_fixture(%{name: "Product Hub"})

      {:ok, view, _html} = live(conn, ~p"/spaces")

      filter(view, "engineering product")

      refute has_element?(view, "#catalog-results", "Engineering Handbook")
      assert has_element?(view, "#catalog-empty", "Nothing matches")
    end

    test "puts the filter in the URL, so a narrowed directory can be shared", %{conn: conn} do
      space_fixture(%{name: "Product Hub"})

      {:ok, view, _html} = live(conn, ~p"/spaces")

      view |> element("#catalog-filter") |> render_change(%{"filter" => %{"q" => "prod"}})

      assert_patch(view, ~p"/spaces?q=prod")
    end

    test "clears the filter again", %{conn: conn} do
      handbook = space_fixture(%{name: "Engineering Handbook"})
      space_fixture(%{name: "Product Hub"})

      {:ok, view, _html} = live(conn, ~p"/spaces?q=prod")

      refute has_element?(view, "#catalog-results a[href='/spaces/#{handbook.key}']")

      view |> element("button[aria-label='Clear filter']") |> render_click()

      assert has_element?(view, "#catalog-results a[href='/spaces/#{handbook.key}']")
    end

    test "reads one page at a time and says how many matches are on screen", %{conn: conn} do
      for n <- 1..55, do: space_fixture(%{name: "Service #{n}"})

      {:ok, view, _html} = live(conn, ~p"/spaces?q=service")

      assert has_element?(view, "#catalog-count", "50+ spaces")
      refute has_element?(view, "#catalog-previous")

      view |> element("#catalog-more") |> render_click()

      assert has_element?(view, "#catalog-count", "5 spaces")
      assert has_element?(view, "#catalog-results", "Service 55")
      refute has_element?(view, "#catalog-more")

      view |> element("#catalog-previous") |> render_click()

      assert has_element?(view, "#catalog-results", "Service 1")
      assert has_element?(view, "#catalog-count", "50+ spaces")
    end
  end

  describe "a space's pages" do
    test "filters pages by title and keeps the section tabs", %{conn: conn} do
      space = space_fixture(%{name: "Engineering Handbook"})
      page_fixture(space, %{title: "Architecture Overview"})
      page_fixture(space, %{title: "Deprecated Setup", status: "archived"})

      {:ok, view, _html} = live(conn, ~p"/spaces/#{space.key}/pages")

      assert has_element?(
               view,
               "nav[aria-label='Space sections'] a[href='/spaces/#{space.key}/attachments']"
             )

      assert has_element?(view, "#catalog-results", "Deprecated Setup")
      assert has_element?(view, "#catalog-results", "Architecture Overview")

      filter(view, "deprecated")

      assert has_element?(view, "#catalog-results", "Deprecated Setup")
      refute has_element?(view, "#catalog-results", "Architecture Overview")
    end
  end

  describe "a space's blog" do
    test "lists the posts of that space only", %{conn: conn} do
      product = space_fixture(%{name: "Product Hub"})
      page_fixture(product, %{title: "Release 2.0", type: "blogpost", slug: "release-2-0"})
      other = space_fixture(%{name: "Engineering Handbook"})

      {:ok, view, _html} = live(conn, ~p"/spaces/#{product.key}/blog")

      assert has_element?(view, "#catalog-results", "Release 2.0")

      {:ok, view, _html} = live(conn, ~p"/spaces/#{other.key}/blog")

      refute has_element?(view, "#catalog-results", "Release 2.0")
    end
  end

  describe "a space's attachments" do
    test "filters files by name", %{conn: conn} do
      space = space_fixture(%{name: "Engineering Handbook"})
      attachment_fixture(page_fixture(space), %{filename: "architecture.csv"})

      {:ok, view, _html} = live(conn, ~p"/spaces/#{space.key}/attachments")

      assert has_element?(view, "#catalog-results", "architecture.csv")

      filter(view, "nothing-like-this")

      assert has_element?(view, "#catalog-empty", "Nothing matches")
    end
  end

  describe "the people directory" do
    test "narrows as the reader types", %{conn: conn} do
      space = space_fixture()
      page_fixture(space, %{author_name: "Jane Doe"})
      page_fixture(space, %{author_name: "Priya Nair"})

      {:ok, view, _html} = live(conn, ~p"/people")

      assert has_element?(view, "#catalog-results", "Jane Doe")

      filter(view, "priya")

      assert has_element?(view, "#catalog-results", "Priya Nair")
      refute has_element?(view, "#catalog-results", "Jane Doe")
    end
  end

  describe "the label index" do
    test "narrows as the reader types", %{conn: conn} do
      space = space_fixture()
      {:ok, _} = Mirror.replace_labels(page_fixture(space), ["release", "roadmap"])

      {:ok, view, _html} = live(conn, ~p"/labels")

      assert has_element?(view, "#catalog-results a[href='/labels/roadmap']")

      filter(view, "release")

      assert has_element?(view, "#catalog-results a[href='/labels/release']")
      refute has_element?(view, "#catalog-results a[href='/labels/roadmap']")
    end
  end

  describe "a space that is not there" do
    test "hands the reader to the page that knows how to answer 404", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/spaces/NOPE/overview"}}} =
               live(conn, ~p"/spaces/NOPE/pages")
    end
  end

  defp filter(view, q) do
    view |> element("#catalog-filter") |> render_change(%{"filter" => %{"q" => q}})
  end
end
