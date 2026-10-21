defmodule ConfluencePhxMirror.Sync.RendererTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.Renderer

  defp context(extra \\ %{}) do
    page = %ConfluencePhxMirror.Mirror.Page{confluence_id: 100, title: "Home"}

    Map.merge(
      %{
        page: page,
        space_key: "ENG",
        base_url: "https://dled.atlassian.net",
        pages: %{
          100 => %{space_key: "ENG", confluence_id: 100, slug: "home"},
          101 => %{space_key: "ENG", confluence_id: 101, slug: "architecture-overview"},
          200 => %{space_key: "PROD", confluence_id: 200, slug: "release-2-0"}
        },
        attachments: %{
          "diagram.svg" => %{
            confluence_id: 9001,
            page_confluence_id: 100,
            space_key: "ENG",
            filename: "diagram.svg"
          }
        }
      },
      extra
    )
  end

  describe "page cross-linking" do
    test "rewrites links to mirrored pages into mirror paths" do
      html =
        ~s(<p><a href="/wiki/spaces/ENG/pages/101/Architecture+Overview">Architecture</a></p>)

      result = Renderer.render(html, context())

      assert result.html =~ ~s(href="/spaces/ENG/pages/101/architecture-overview")

      assert [%{kind: "internal", target_confluence_id: 101, label: "Architecture"}] =
               result.links
    end

    test "rewrites cross-space page links" do
      html =
        ~s(<a href="https://dled.atlassian.net/wiki/spaces/PROD/pages/200/Release+2.0">R2</a>)

      assert Renderer.render(html, context()).html =~
               ~s(href="/spaces/PROD/pages/200/release-2-0")
    end

    test "keeps links to pages that were not mirrored absolute" do
      html = ~s(<a href="/wiki/spaces/ENG/pages/999/Hidden">Hidden</a>)

      result = Renderer.render(html, context())

      assert result.html =~ ~s(href="https://dled.atlassian.net/pages/viewpage.action?pageId=999")
      assert [%{kind: "external", target_confluence_id: 999}] = result.links
    end

    test "keeps in-page anchors untouched" do
      assert Renderer.render(~s(<a href="#details">Details</a>), context()).html =~
               ~s(href="#details")
    end
  end

  describe "attachments" do
    test "rewrites attachment links to the mirrored blob route" do
      html = ~s(<a href="/wiki/download/attachments/100/diagram.svg?version=2">diagram</a>)

      result = Renderer.render(html, context())

      assert result.html =~ ~s(href="/attachments/ENG/100/9001/diagram.svg")
      assert [%{kind: "attachment"}] = result.links
    end

    test "rewrites embedded images to the mirror and makes them lazy" do
      html =
        ~s(<img class="confluence-embedded-image" src="/wiki/download/attachments/100/diagram.svg?api=v2" />)

      result = Renderer.render(html, context())

      assert result.html =~ ~s(src="/attachments/ENG/100/9001/diagram.svg")
      assert result.html =~ ~s(loading="lazy")
      assert result.html =~ ~s(alt="")
    end

    test "keeps attachments of other pages pointing at the source" do
      html = ~s(<img src="/wiki/download/attachments/999/other.png" />)

      assert Renderer.render(html, context()).html =~
               ~s(src="https://dled.atlassian.net/wiki/download/attachments/999/other.png")
    end
  end

  describe "external links" do
    test "makes relative links absolute and adds safe rel attributes" do
      html = ~s(<a href="/browse/ENG-42">ENG-42</a> <a href="https://example.com/x">x</a>)

      result = Renderer.render(html, context())

      assert result.html =~ ~s(href="https://dled.atlassian.net/browse/ENG-42")
      assert result.html =~ ~s(rel="noopener noreferrer")
      assert result.html =~ ~s(target="_blank")
    end
  end

  describe "sanitising" do
    test "removes scripts and event handler attributes" do
      html = """
      <div onclick="steal()">safe</div>
      <script>alert(1)</script>
      <a href="javascript:alert(1)">click</a>
      <img src="/wiki/download/attachments/100/diagram.svg" onerror="alert(2)" />
      """

      result = Renderer.render(html, context())

      refute result.html =~ "script"
      refute result.html =~ "onclick"
      refute result.html =~ "onerror"
      refute result.html =~ "javascript:"
    end

    test "removes iframes and forms" do
      html =
        ~s(<iframe src="https://evil.example"></iframe><form action="/x"><input /></form><p>kept</p>)

      result = Renderer.render(html, context())

      refute result.html =~ "iframe"
      refute result.html =~ "form"
      assert result.html =~ "kept"
    end
  end

  describe "text" do
    test "extracts readable plain text for full-text search" do
      html = "<h1>Title</h1><p>Some <strong>bold</strong> text.</p>"

      assert Renderer.render(html, context()).text == "Title Some bold text."
    end
  end
end
