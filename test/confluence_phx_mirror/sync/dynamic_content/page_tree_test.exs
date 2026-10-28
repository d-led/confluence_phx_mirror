defmodule ConfluencePhxMirror.Sync.DynamicContent.PageTreeTest do
  @moduledoc """
  *Page Tree* resolved from the ancestor trail.

  A tree is the one macro where the shape matters as much as the words: a child
  that appears beside its parent instead of under it is a different tree, and a
  reader navigates by the shape.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="pagetree"></div>)
  @space %{key: "ENG"}
  @root %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Runbooks", space: @space}

  setup do
    StubContent.script(
      descendants: [
        page(2, "Deploys", 1),
        page(3, "Rollbacks", 1),
        page(4, "Blue-green", 2)
      ]
    )
  end

  test "nests every page below its parent" do
    assert outline(expand()) == [{"Deploys", 1}, {"Blue-green", 2}, {"Rollbacks", 1}]
  end

  test "the tree carries the class the stylesheet draws" do
    assert Floki.find(document(expand()), "ul.mirror-tree") != []
  end

  test "links each page through the reader route" do
    assert hrefs(expand()) == [
             "/spaces/ENG/pages/2/Deploys",
             "/spaces/ENG/pages/4/Blue+green",
             "/spaces/ENG/pages/3/Rollbacks"
           ]
  end

  test "reads the tree below the page carrying the macro" do
    expand()

    assert StubContent.questions() == [{:descendants, [limit: 50]}]
  end

  test "reads no more pages than the marker allows" do
    expand(~s(<div class="mirror-macro" data-macro="pagetree" data-limit="7"></div>))

    assert StubContent.questions() == [{:descendants, [limit: 7]}]
  end

  test "resolves a named root through the port before reading its tree" do
    StubContent.script(
      page_by_title: {:ok, page(9, "Operations", nil)},
      descendants: [page(10, "On call", 9)]
    )

    marker =
      ~s(<div class="mirror-macro" data-macro="pagetree" data-root="Operations"></div>)

    assert outline(expand(marker)) == [{"On call", 1}]

    assert StubContent.questions() == [
             {:page_by_title, "Operations"},
             {:descendants, [limit: 50]}
           ]
  end

  test "a root the port cannot resolve is said out loud, not drawn empty" do
    html = expand(~s(<div class="mirror-macro" data-macro="pagetree" data-root="Typo"></div>))

    assert text(html) == "The page tree's root is not in the mirror, or not readable here."
    assert title_list(html) == []
  end

  test "says so when there is nothing below the root" do
    StubContent.script(descendants: [])

    assert text(expand()) == "This page tree has no pages below its root."
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @root, source: StubContent})

  # The tree as a reader sees it: each title with how deep it hangs.
  defp outline(html), do: html |> document() |> Enum.flat_map(&walk(&1, 0))

  defp walk({"ul", _attrs, children}, depth), do: Enum.flat_map(children, &walk(&1, depth + 1))

  defp walk({"li", _li_attrs, [{"a", _a_attrs, [title]} | rest]}, depth),
    do: [{title, depth} | Enum.flat_map(rest, &walk(&1, depth))]

  defp walk({_tag, _attrs, children}, depth), do: Enum.flat_map(children, &walk(&1, depth))
  defp walk(_node, _depth), do: []

  defp hrefs(html) do
    html
    |> title_list()
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end

  defp title_list(html), do: html |> document() |> Floki.find("ul.mirror-tree li a")

  defp text(html), do: html |> document() |> Floki.text()

  defp document(html), do: Floki.parse_fragment!(html)

  defp page(id, title, parent_id) do
    %{
      id: id,
      confluence_id: id,
      parent_id: parent_id,
      title: title,
      slug: Page.slugify(title),
      type: "page",
      space: @space,
      external_updated_at: ~U[2026-10-01 09:00:00Z]
    }
  end
end
