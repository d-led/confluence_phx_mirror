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
          101 => %{space_key: "ENG", confluence_id: 101, slug: "Architecture+Overview"},
          200 => %{space_key: "PROD", confluence_id: 200, slug: "Release+2+0"}
        },
        attachments: %{
          {100, "diagram.svg"} => %{
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

      assert result.html =~ ~s(href="/spaces/ENG/pages/101/Architecture+Overview")

      assert [%{kind: "internal", target_confluence_id: 101, label: "Architecture"}] =
               result.links
    end

    test "rewrites cross-space page links" do
      html =
        ~s(<a href="https://dled.atlassian.net/wiki/spaces/PROD/pages/200/Release+2.0">R2</a>)

      assert Renderer.render(html, context()).html =~
               ~s(href="/spaces/PROD/pages/200/Release+2+0")
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

    test "resolves a file that lives in a comment, served under its page" do
      # Observed on a real site: Confluence's export view rewrites an image
      # pasted into a comment to the *page's* download path, so the page is the
      # owner the markup claims.
      comment_file =
        context(%{
          attachments: %{
            {100, "screenshot.png"} => %{
              confluence_id: 9101,
              page_confluence_id: 100,
              space_key: "ENG",
              filename: "screenshot.png"
            }
          }
        })

      html = ~s(<img src="/wiki/download/attachments/100/screenshot.png?api=v2" />)

      assert Renderer.render(html, comment_file).html =~
               ~s(src="/attachments/ENG/100/9101/screenshot.png")
    end

    test "a file of the same name on another page is not this page's file" do
      html = ~s(<img src="/wiki/download/attachments/300/diagram.svg" />)

      assert Renderer.render(html, context()).html =~
               ~s(src="https://dled.atlassian.net/wiki/download/attachments/300/diagram.svg")
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

  describe "content the mirror cannot render" do
    test "an app iframe becomes a placeholder that says so" do
      html = ~s(<p>before</p><iframe src="https://apps.example/embed"></iframe><p>after</p>)

      result = Renderer.render(html, context())

      assert result.html =~ "This embedded content is rendered live by Confluence."
      assert result.html =~ "before"
      assert result.html =~ "after"
    end

    test "a macro Confluence did not expand into the export becomes a placeholder" do
      html = """
      <ac:structured-macro ac:name="jira">
        <ac:parameter ac:name="jql">project = ENG</ac:parameter>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context(%{page: page()}))

      assert result.html =~ "export renderer is not yet implemented."
      assert result.html =~ "a Jira issues search"
      assert result.html =~ "original page"
    end

    test "the placeholder links back to the original page" do
      html = ~s(<ac:structured-macro ac:name="pagetree"></ac:structured-macro>)

      assert Renderer.render(html, context(%{page: page()})).html =~
               ~s(href="#{page().external_url}")
    end

    test "an unknown macro is named as it is" do
      html = ~s(<ac:structured-macro ac:name="acme-widget"></ac:structured-macro>)

      assert Renderer.render(html, context()).html =~ "the acme-widget macro"
    end

    test "a macro nobody can draw keeps the body a reader came for" do
      html = """
      <ac:structured-macro ac:name="confiform-table">
        <ac:parameter ac:name="formName">Holidays</ac:parameter>
        <ac:rich-text-body><p>The holiday calendar lives here.</p></ac:rich-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ "export renderer is not yet implemented"
      assert result.html =~ "ConfiForms table"
      assert result.html =~ "The holiday calendar lives here."
    end

    test "a vendor layout macro is drawn instead of apologised for" do
      html = """
      <ac:structured-macro ac:name="aura-tab-group">
        <ac:rich-text-body>
          <ac:structured-macro ac:name="aura-tab">
            <ac:parameter ac:name="title">Install</ac:parameter>
            <ac:rich-text-body><p>Run mix setup.</p></ac:rich-text-body>
          </ac:structured-macro>
        </ac:rich-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ "mirror-aura-tabs"
      assert result.html =~ "<summary>Install</summary>"
      assert result.html =~ "Run mix setup."
      refute result.html =~ "not yet implemented"
    end
  end

  defp page do
    %ConfluencePhxMirror.Mirror.Page{
      confluence_id: 100,
      title: "Home",
      external_url: "https://dled.atlassian.net/wiki/spaces/ENG/pages/100/Home"
    }
  end

  describe "macros" do
    test "turns the expand macro into a native details element" do
      html = """
      <div class="expand-container">
        <div class="expand-control"><span class="expand-control-icon">▶</span> <span class="expand-control-text">More details</span></div>
        <div class="expand-content" style="display: none;"><p>Hidden <a href="/wiki/spaces/ENG/pages/101/Architecture">link</a></p></div>
      </div>
      """

      result = Renderer.render(html, context())

      assert result.html =~ "<details"
      assert result.html =~ "<summary"
      assert result.html =~ "More details"
      refute result.html =~ "expand-control-icon"
      refute result.html =~ "display: none"
      assert result.html =~ ~s(href="/spaces/ENG/pages/101/Architecture+Overview")
    end
  end

  describe "inline spacing" do
    test "keeps the space between two inline elements" do
      html =
        ~s(<p>Statuses: <span class="aui-lozenge">DONE</span> <span class="aui-lozenge">MOVED</span></p>)

      assert Renderer.render(html, context()).html =~
               ~s(<p>Statuses: <span class="aui-lozenge">DONE</span> <span class="aui-lozenge">MOVED</span></p>)
    end

    test "keeps the original whitespace inside preformatted text" do
      html = "<pre><span>a</span>\n   <span>b</span></pre>"

      assert Renderer.render(html, context()).html =~
               "<pre><span>a</span>\n   <span>b</span></pre>"
    end
  end

  describe "text" do
    test "extracts readable plain text for full-text search" do
      html = "<h1>Title</h1><p>Some <strong>bold</strong> text.</p>"

      assert Renderer.render(html, context()).text == "Title Some bold text."
    end

    test "leaves Confluence's inline colour rules out of the text" do
      html = """
      <style>[data-colorid=aruk1kcdwm]{color:#97a0af}</style>
      <p data-colorid="aruk1kcdwm">Coloured panel text</p>
      """

      text = Renderer.render(html, context()).text

      assert text == "Coloured panel text"
      refute text =~ "data-colorid="
    end
  end

  describe "emoticons" do
    test "an export-view emoticon image becomes the character, not an external image" do
      html = """
      <p>Ship it <img class="emoticon emoticon-tick" data-emoticon-name="tick"
                      alt="(tick)" src="https://dled.atlassian.net/wiki/images/icons/emoticons/check.png" /></p>
      """

      result = Renderer.render(html, context())

      assert result.html =~ "Ship it ✅"
      refute result.html =~ "<img"
      assert result.text =~ "✅"
    end

    test "an emoji keeps the character Confluence stored for it" do
      html = """
      <p>Party <img class="emoticon emoticon-smile" data-emoji-shortname=":slight_smile:"
                      data-emoji-fallback="🙂" src="https://dled.atlassian.net/wiki/images/icons/emoticons/smile.png"
                      alt="(smile)" /></p>
      """

      assert Renderer.render(html, context()).html =~ "Party 🙂"
    end

    test "an image it cannot name stays an image" do
      html =
        ~s(<p>Odd <img class="transform-error" src="https://dled.atlassian.net/placeholder/error" /></p>)

      assert Renderer.render(html, context()).html =~ "<img"
    end
  end
end
