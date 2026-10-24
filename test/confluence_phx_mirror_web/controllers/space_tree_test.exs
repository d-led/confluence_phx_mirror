defmodule ConfluencePhxMirrorWeb.SpaceTreeTest do
  @moduledoc """
  The sidebar ships the trail to the page being read and nothing else: a branch
  opens when a reader asks for it, and the catalog pages through the rest.

  A space with hundreds of pages under one front page was the case that made
  this necessary — the page used to arrive with every child in it.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest, only: [has_element: 2]

  alias ConfluencePhxMirror.Mirror

  describe "the sidebar branch" do
    test "answers with the node's children, ready for the tree", %{conn: conn} do
      space = space_fixture(%{key: "TREE"})
      root = page_fixture(space, %{title: "Root", confluence_id: 9001})
      alpha = page_fixture(space, %{title: "Alpha", confluence_id: 9002, parent_id: root.id})
      page_fixture(space, %{title: "Beta", confluence_id: 9003, parent_id: root.id})
      page_fixture(space, %{title: "Deeper", confluence_id: 9004, parent_id: alpha.id})

      body = conn |> get(~p"/spaces/#{space.key}/tree/#{root.id}") |> html_response(200)

      # A fragment for the list, not a page of its own.
      refute body =~ "<!DOCTYPE"
      assert body =~ "Alpha"
      assert body =~ "Beta"
      refute body =~ ">Root<", "the branch is the children, not the node again"
      # Alpha has a child, so it arrives with a place waiting for one.
      assert body =~ ~s(data-tree-children="#{alpha.id}")
    end

    test "a page of another space is not served here", %{conn: conn} do
      space = space_fixture(%{key: "MINE"})
      elsewhere = space_fixture(%{key: "OTHER"})
      stranger = page_fixture(elsewhere, %{title: "Not yours"})

      assert conn |> get(~p"/spaces/#{space.key}/tree/#{stranger.id}") |> response(404) =~
               "No such page in MINE."
    end
  end

  describe "the child list on a page" do
    test "shows a window, the real count, and where the rest lives", %{conn: conn} do
      space = space_fixture(%{key: "BIG"})
      home = page_fixture(space, %{title: "Home", confluence_id: 91_001})

      for n <- 1..14 do
        page_fixture(space, %{title: "Child #{n}", confluence_id: 91_000 + n, parent_id: home.id})
      end

      html =
        conn
        |> get(~p"/spaces/#{space.key}/pages/#{home.confluence_id}/#{home.slug}")
        |> html_response(200)

      document = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(document, "nav[aria-label='Child pages'] li")) == 10
      assert LazyHTML.query(document, "nav[aria-label='Child pages']") |> LazyHTML.text() =~ "14"
      assert html =~ "Browse all pages in BIG"
    end
  end

  describe "the tree data" do
    test "a node knows whether it has children to open" do
      space = space_fixture(%{key: "FLAG"})
      leaf = page_fixture(space, %{title: "Leaf", confluence_id: 92_001})
      branch = page_fixture(space, %{title: "Branch", confluence_id: 92_002})
      page_fixture(space, %{title: "Below", confluence_id: 92_003, parent_id: branch.id})

      roots = Mirror.branch_tree(space.id).nodes

      assert %{page: %{has_children: true}} = Enum.find(roots, &(&1.page.id == branch.id))
      assert %{page: %{has_children: false}} = Enum.find(roots, &(&1.page.id == leaf.id))

      [child] = Mirror.tree_children(space.id, branch)
      assert child.title == "Below"
      assert child.has_children == false
    end
  end
end
