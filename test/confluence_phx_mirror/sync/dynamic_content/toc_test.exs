defmodule ConfluencePhxMirror.Sync.DynamicContent.TocTest do
  @moduledoc """
  *Table of Contents* resolved from the body being expanded.

  What a reader needs from a table of contents is one thing: every heading of the
  page, in order, as a link to its own anchor, nested the way the headings nest.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent

  @marker ~s(<div class="mirror-macro" data-macro="toc"></div>)
  @page %{id: 1, confluence_id: 1002, slug: "page-1002", title: "Page", space: %{key: "ENG"}}

  test "lists the page's headings as links to their anchors" do
    html = expand(~s(<h2 id="tasks">Tasks</h2><h2 id="gallery">Gallery</h2>))

    assert links(html) == [{"#tasks", "Tasks"}, {"#gallery", "Gallery"}]
  end

  test "keeps the headings in the order the page has them" do
    html = expand(~s(<h2 id="one">One</h2><h2 id="two">Two</h2><h2 id="three">Three</h2>))

    assert Enum.map(links(html), fn {_, text} -> text end) == ["One", "Two", "Three"]
  end

  test "nests a heading below the one above it" do
    html = expand(~s(<h2 id="a">A</h2><h3 id="a-1">A.1</h3><h2 id="b">B</h2>))

    assert nested(html) == [{"#a", ["#a-1"]}, {"#b", []}]
  end

  test "skips headings a level the marker does not ask for" do
    html =
      expand(
        ~s(<h1 id="title">Title</h1><h2 id="body">Body</h2>),
        ~s(<div class="mirror-macro" data-macro="toc" data-min-level="2"></div>)
      )

    assert links(html) == [{"#body", "Body"}]
  end

  test "says so when the page has no headings at all" do
    assert expand("<p>Just a paragraph.</p>") =~ "This page has no headings to list."
  end

  test "survives a heading without an id, because there is nothing to link to" do
    html = expand(~s(<h2>Loose</h2><h2 id="kept">Kept</h2>))

    assert links(html) == [{"#kept", "Kept"}]
  end

  defp expand(body), do: expand(body, @marker)

  defp expand(body, marker) do
    DynamicContent.expand(body <> marker, %{space: @page.space, page: @page})
  end

  defp document(html), do: Floki.parse_fragment!(html)

  defp links(html) do
    html
    |> document()
    |> Floki.find("ul.mirror-toc a")
    |> Enum.map(&{Floki.attribute(&1, "href") |> hd(), Floki.text(&1)})
  end

  # The outermost list only: each entry with the anchors of the list nested
  # inside it, which is how nesting is told apart from a flat list.
  defp nested(html) do
    [{"ul", _attrs, items} | _deeper] = html |> document() |> Floki.find("ul.mirror-toc")

    Enum.map(items, fn {"li", _, [{"a", attrs, _children} | rest]} ->
      {attr(attrs, "href"),
       rest |> Floki.find("a") |> Enum.map(&Floki.attribute(&1, "href")) |> List.flatten()}
    end)
  end

  defp attr(attrs, name), do: attrs |> List.keyfind(name, 0) |> elem(1)
end
