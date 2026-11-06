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
    # The origin, never the page: a player may refuse to start with no referrer
    # at all, and the page's address is not the third party's business.
    assert iframe(html)["referrerpolicy"] == "origin"
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

  # The macro records the size the vendor's player is built for. The height is
  # that band; the width is the reading column's, so a page cannot hand a phone
  # a sideways scroll.
  test "a declared height is the frame's height, and the width is not taken from the macro" do
    html =
      expand(
        ~s(<div class="mirror-macro" data-macro="widget" data-url="#{@address}") <>
          ~s(data-width="600px" data-height="315px"></div>)
      )

    assert iframe(html)["style"] == "height:315px"
  end

  test "a height no player comes in is clamped to a frame a reader can use" do
    assert iframe(expand(marked_at_height("10px")))["style"] == "height:120px"
    assert iframe(expand(marked_at_height("5000px")))["style"] == "height:1200px"
  end

  test "a height that is not a pixel count leaves the frame at its own shape" do
    assert iframe(expand(marked_at_height("100%")))["style"] == nil
  end

  test "an address that is not a web address is named, not linked" do
    html =
      expand(
        ~s{<div class="mirror-macro" data-macro="widget" data-url="javascript:alert(1)"></div>}
      )

    assert hrefs(html) == []
    assert html =~ "not a web address"
  end

  # The template is what knows what the address *is*. YouTube refuses to be
  # framed and serves a player only from `/embed/`, so the frame gets that
  # address while the page keeps the one the author pasted — timestamps and all.
  describe "a widget connector whose template names the vendor" do
    @youtube "com/atlassian/confluence/extra/widgetconnector/templates/youtube.vm"
    @watch "https://www.youtube.com/watch?v=ii1waoqualY"

    test "is framed at the address the vendor's player is served from" do
      html = expand(templated(@watch, @youtube))

      assert iframe(html)["src"] == "https://www.youtube.com/embed/ii1waoqualY"
      assert hrefs(html) == [@watch]
    end

    # Only the frame's host is asked for, which is why a pasted short link needs
    # no second host in the list.
    test "is the same frame when the author pasted the short link" do
      html = expand(templated("https://youtu.be/ii1waoqualY", @youtube))

      assert iframe(html)["src"] == "https://www.youtube.com/embed/ii1waoqualY"
      assert hrefs(html) == ["https://youtu.be/ii1waoqualY"]
    end

    test "is a frame only where the host it loads was named" do
      TestConfig.put(:embed_hosts, [])

      html = expand(templated(@watch, @youtube))

      assert iframe(html) == %{}
      assert hrefs(html) == [@watch]
    end

    # A template says what the address is, it never makes an address frameable:
    # a video the player cannot take is the address, not a blank box.
    test "falls back to the address when the vendor cannot play it" do
      html = expand(templated("https://www.youtube.com/feed/subscriptions", @youtube))

      assert iframe(html) == %{}
      assert hrefs(html) == ["https://www.youtube.com/feed/subscriptions"]
    end

    # Nobody has seen this vendor's template, so nothing is known about how its
    # player spells an address: the host is framed as it stands.
    test "is framed as it stands when nobody here knows the vendor" do
      TestConfig.put(:embed_hosts, ["vimeo.com"])

      html =
        expand(
          templated(
            "https://vimeo.com/123456",
            "com/atlassian/confluence/extra/widgetconnector/templates/vimeo.vm"
          )
        )

      assert iframe(html)["src"] == "https://vimeo.com/123456"
    end
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

  defp marked_at_height(height) do
    ~s(<div class="mirror-macro" data-macro="widget" data-url="#{@address}") <>
      ~s( data-height="#{height}"></div>)
  end

  defp templated(address, template) do
    ~s(<div class="mirror-macro" data-macro="widget" data-url="#{address}") <>
      ~s( data-template="#{template}"></div>)
  end

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
