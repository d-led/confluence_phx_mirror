defmodule ConfluencePhxMirror.Sync.DynamicContent.AnchorTest do
  @moduledoc """
  *Anchor* records a name a link can point at.

  The macro draws nothing and carries nothing; `export_view` leaves a picture of
  it, and Confluence keeps the name in a parameter with no name of its own. Two
  claims are pinned: that name reaches the marker, and the expanded body carries
  the id a `#name` link lands on.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.Marker
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}
  @marker ~s(<div class="mirror-macro" data-macro="anchor" data-name="section-two"></div>)

  test "the name it records is where a link lands" do
    assert ids(expand(@marker)) == ["section-two"]
  end

  test "the storage's nameless parameter is the name the marker carries" do
    assert {:ok, {"div", attributes, []}} = Marker.build("anchor", [{"", "section-two"}])

    assert {"data-name", "section-two"} in attributes
  end

  test "an anchor that names nothing says so instead of linking nowhere" do
    assert expand(~s(<div class="mirror-macro" data-macro="anchor"></div>)) =~
             "names nothing"
  end

  defp expand(marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp ids(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("a.mirror-anchor")
    |> Enum.map(&Floki.attribute(&1, "id"))
    |> List.flatten()
  end
end
