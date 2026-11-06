defmodule ConfluencePhxMirror.Sync.DynamicContent.WidgetConnectorTest do
  @moduledoc """
  *Widget Connector*: a third party's page, drawn only where an operator allowed
  the host — and always with its address under it.

  Confluence resolves the macro in the reader's browser, so the export carries it
  unexpanded and the mirror used to print "an external widget" instead. What it
  holds is an address, which is enough to draw it, and the address stays on the
  page for every case where the frame cannot be there.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent
  alias ConfluencePhxMirror.TestConfig

  @address "https://www.youtube.com/watch?v=abc"
  @marker ~s(<div class="mirror-macro" data-macro="widget" data-url="#{@address}"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    TestConfig.put(:embed_hosts, ["youtube.com"])
  end

  test "an allowed host is a frame, and the address is printed under it" do
    html = expand()

    assert iframe(html)["src"] == @address
    assert iframe(html)["loading"] == "lazy"
    assert iframe(html)["referrerpolicy"] == "no-referrer"
    # A third party's page runs its own scripts; it does not get to reach ours.
    assert iframe(html)["sandbox"] =~ "allow-scripts"

    assert hrefs(html) == [@address]
  end

  # The frame is the part that may be missing, so the address is not a fallback
  # that only some renders get: it is always there, quiet, and still a link.
  test "a host nobody named leaves the address and no frame" do
    TestConfig.put(:embed_hosts, [])

    html = expand()

    assert iframe(html) == %{}
    assert hrefs(html) == [@address]
    assert html =~ "mirror-embed-address"
  end

  # One copy of a body is served to every reader, and a page a stranger may open
  # is stored without a frame: otherwise every reader of it loads a third party.
  test "a space a stranger may read is stored without the frame" do
    TestConfig.put(:public_spaces, ["ENG"])

    html = expand()

    assert iframe(html) == %{}
    assert hrefs(html) == [@address]
  end

  test "a public deployment embeds nowhere" do
    TestConfig.put(:public_site, true)

    assert iframe(expand()) == %{}
  end

  test "an address that is not a web address is named, not linked" do
    html =
      expand(
        ~s{<div class="mirror-macro" data-macro="widget" data-url="javascript:alert(1)"></div>}
      )

    assert hrefs(html) == []
    assert html =~ "not a web address"
  end

  test "a macro that names no address says so instead of drawing an empty box" do
    assert expand(~s(<div class="mirror-macro" data-macro="widget"></div>)) =~
             "names no address"
  end

  test "the name Confluence's own documentation gives it draws the same widget" do
    html =
      expand(
        ~s(<div class="mirror-macro" data-macro="widget-connector" data-url="#{@address}"></div>)
      )

    assert iframe(html)["src"] == @address
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp iframe(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("iframe.mirror-embed")
    |> List.first()
    |> case do
      nil -> %{}
      {_tag, attrs, _children} -> Map.new(attrs)
    end
  end

  defp hrefs(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("p.mirror-embed-address a")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end
end
