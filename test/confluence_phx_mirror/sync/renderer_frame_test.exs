defmodule ConfluencePhxMirror.Sync.RendererFrameTest do
  @moduledoc """
  The one third party a mirrored page may load: a widget connector's frame.

  The site renders the vendor's player into `export_view` as an `iframe`, so the
  frame is content rather than live-only — but only where an operator named that
  host, and only for a body no stranger reads. What is kept is the mirror's own
  frame node (`Sync.Embeds.Frame`), not the site's markup: sandboxed, no
  referrer, lazy, and sized by the height the page declared.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.Renderer
  alias ConfluencePhxMirror.TestConfig

  @player ~s(<iframe src="https://www.youtube.com/embed/ii1waoqualY" width="600" height="300"></iframe>)

  test "is kept, as the mirror's own frame, where an operator allowed the host" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    html = render(@player)

    assert frame(html)["src"] == "https://www.youtube.com/embed/ii1waoqualY"
    assert frame(html)["sandbox"] =~ "allow-scripts"
    # The site's origin, not the page's address: YouTube refuses to play with no
    # referrer at all ("Error 153"), and a page's address is not its business.
    assert frame(html)["referrerpolicy"] == "origin"
    assert frame(html)["loading"] == "lazy"
    # The size the page declared, and no width of its own: the frame fills the
    # reading column.
    assert frame(html)["style"] == "height:300px"
    refute html =~ "cannot be shown"
  end

  test "is not kept where nobody named the host" do
    TestConfig.put(:embed_hosts, [])

    html = render(@player)

    assert frame(html) == %{}
    assert html =~ "This embedded content is rendered live by Confluence."
  end

  # One copy of a body is served to every reader: a frame in a body a stranger
  # opens would load the third party for everybody who reads it.
  test "is not kept for a page a stranger may read" do
    TestConfig.put(:embed_hosts, ["youtube.com"])
    TestConfig.put(:public_spaces, ["ENG"])

    html = render(@player)

    assert frame(html) == %{}
    assert html =~ "cannot be shown"
  end

  test "is not kept when the address is not https" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    html = render(~s(<iframe src="http://www.youtube.com/embed/ii1waoqualY"></iframe>))

    assert frame(html) == %{}
  end

  # The address Confluence actually writes: no scheme, and the player's own
  # parameters. Read as "not a web address", every real widget was a notice.
  test "is kept when the site wrote the address without a scheme" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    html =
      render(
        ~s(<iframe class="youtube-player" style="width: 600px; height: 300px" ) <>
          ~s(src="//www.youtube.com/embed/ii1waoqualY?wmode=opaque" frameborder="0"></iframe>)
      )

    assert frame(html)["src"] == "https://www.youtube.com/embed/ii1waoqualY?wmode=opaque"
    assert frame(html)["style"] == "height:300px"
  end

  test "a frame with no address is the notice, not an empty box" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    html = render(~s(<iframe></iframe>))

    assert frame(html) == %{}
    assert html =~ "cannot be shown"
  end

  defp render(html) do
    Renderer.render(html, %{
      page: %ConfluencePhxMirror.Mirror.Page{confluence_id: 100, title: "Home"},
      space_key: "ENG",
      base_url: "https://dled.atlassian.net"
    }).html
  end

  defp frame(html) do
    case html |> Floki.parse_fragment!() |> Floki.find("iframe.mirror-embed") |> List.first() do
      nil -> %{}
      {_tag, attrs, _children} -> Map.new(attrs)
    end
  end
end
