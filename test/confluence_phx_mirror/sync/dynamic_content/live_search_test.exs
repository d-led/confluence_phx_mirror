defmodule ConfluencePhxMirror.Sync.DynamicContent.LiveSearchTest do
  @moduledoc """
  *Live search*: the site's search box, which a static mirror cannot run.

  The macro stores nothing to search for — no query, no scope — so it becomes the
  way to the mirror's own search, narrowed to the space the page sits in.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="livesearch"></div>)
  @page %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering"}

  test "a page in a space is offered that space's search first, and the whole mirror after it" do
    links = links(expand(%{key: "ENG"}))

    assert links == [{"this space", "/search?space=ENG"}, {"the whole mirror", "/search"}]
  end

  test "a page with no space to narrow to is offered the mirror's search" do
    assert links(expand(%{})) == [{"the mirror", "/search"}]
  end

  defp expand(space) do
    DynamicContent.expand(@marker, %{space: space, page: @page, source: StubContent})
  end

  defp links(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("p.mirror-dynamic-search a")
    |> Enum.map(&{Floki.text(&1), Floki.attribute(&1, "href") |> List.first()})
  end
end
