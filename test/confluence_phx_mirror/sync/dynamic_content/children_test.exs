defmodule ConfluencePhxMirror.Sync.DynamicContent.ChildrenTest do
  @moduledoc """
  *Children Display* resolved from the page tree.

  The interesting part is not the list — it is which pages may be in it. A macro
  is resolved once at sync time for every reader of the host page, so a child
  list that names a restricted page would hand a restriction away.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="children"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Getting Started", space: @space}

  setup do
    StubContent.script(
      children: [page(1002, "Architecture Overview"), page(1003, "Macros Gallery")]
    )
  end

  test "lists the pages below this one, linked through the reader route" do
    assert titles(expand()) == ["Architecture Overview", "Macros Gallery"]

    assert hrefs(expand()) == [
             "/spaces/ENG/pages/1002/Architecture+Overview",
             "/spaces/ENG/pages/1003/Macros+Gallery"
           ]
  end

  test "names the space and the day each page was last updated" do
    assert expand() =~ "· ENG · updated 01 Oct 2026"
  end

  test "says so when the page has no children" do
    StubContent.script(children: [])

    assert expand() =~ "This page has no child pages."
  end

  test "asks the port only for what the marker allows" do
    assert asks_for(a_limit_of("7")) == [limit: 7]
    assert asks_for(@marker) == [limit: 50]
  end

  defp asks_for(marker) do
    expand(marker)
    StubContent.asked()
  end

  defp a_limit_of(limit),
    do: ~s(<div class="mirror-macro" data-macro="children" data-limit="#{limit}"></div>)

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp titles(html),
    do: html |> document() |> Floki.find("ul.mirror-dynamic-list a") |> Enum.map(&Floki.text/1)

  defp hrefs(html) do
    html
    |> document()
    |> Floki.find("ul.mirror-dynamic-list a")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end

  defp document(html), do: Floki.parse_fragment!(html)

  defp page(id, title) do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: ConfluencePhxMirror.Mirror.Page.slugify(title),
      type: "page",
      space: @space,
      external_updated_at: ~U[2026-10-01 12:00:00Z]
    }
  end
end
