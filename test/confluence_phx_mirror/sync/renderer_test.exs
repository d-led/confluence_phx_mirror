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

  # The `data-source` a rendered body carries: the one attribute a macro's own
  # document reaches its renderer by.
  defp source(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("[data-source]")
    |> Floki.attribute("data-source")
    |> List.first()
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

    test "keeps the place a link to another page names" do
      # A table of contents is a page full of these. Without the fragment every
      # entry links back to the page the reader is already on, and pressing one
      # looks like nothing happening.
      html =
        ~s(<a href="/wiki/spaces/ENG/pages/101/Architecture+Overview#Design">Design</a>)

      assert Renderer.render(html, context()).html =~
               ~s(href="/spaces/ENG/pages/101/Architecture+Overview#Design")
    end

    test "keeps the place a link to an unmirrored page names" do
      html = ~s(<a href="/wiki/spaces/ENG/pages/999/Hidden#Notes">Notes</a>)

      assert Renderer.render(html, context()).html =~
               ~s(href="https://dled.atlassian.net/pages/viewpage.action?pageId=999#Notes")
    end
  end

  describe "space cross-linking" do
    # A body that names a space names a screen the mirror has. Left as it came
    # out of the export, the name is a link off the mirror to the site — where a
    # reader of a public mirror has no account at all.
    test "a link that names a space stays in the mirror" do
      html =
        ~s(<p>The <a href="https://dled.atlassian.net/wiki/spaces/PROD">release space</a></p>)

      result = Renderer.render(html, context(%{space_lookup: &space_named/1}))

      assert result.html =~ ~s(href="/spaces/PROD")
      assert [%{kind: "internal", label: "release space"}] = result.links
    end

    test "the legacy address of a space home is the same space" do
      html = ~s(<a href="/wiki/display/PROD">release space</a>)

      assert Renderer.render(html, context(%{space_lookup: &space_named/1})).html =~
               ~s(href="/spaces/PROD")
    end

    test "a space nobody mirrored keeps its link to the site" do
      html = ~s(<a href="https://dled.atlassian.net/wiki/spaces/ELSEWHERE">elsewhere</a>)

      assert Renderer.render(html, context(%{space_lookup: &space_named/1})).html =~
               ~s(href="https://dled.atlassian.net/wiki/spaces/ELSEWHERE")
    end

    test "a page inside a space is still a page, not the space" do
      html = ~s(<a href="/wiki/spaces/ENG/pages/101/Architecture+Overview">Architecture</a>)

      assert Renderer.render(html, context(%{space_lookup: &space_named/1})).html =~
               ~s(href="/spaces/ENG/pages/101/Architecture+Overview")
    end

    # The mirror's own spelling of the key is what a path must carry: the site
    # writes keys in capitals, a body may link them any way it likes.
    test "the mirror's spelling of the key is the one written into the path" do
      html = ~s(<a href="/wiki/spaces/prod">release space</a>)

      assert Renderer.render(html, context(%{space_lookup: &space_named/1})).html =~
               ~s(href="/spaces/PROD")
    end

    defp space_named(key) when is_binary(key) do
      key = String.upcase(key)
      if key == "PROD", do: %ConfluencePhxMirror.Mirror.Space{key: key}
    end
  end

  describe "a name in a body" do
    # Confluence writes a mention as a link to the site's people page. The mirror
    # has a page per author, so the name stays a link here — a reader of a closed
    # deployment has no account on the site to be sent to.
    test "a name is the person's page here" do
      html =
        ~s(<a class="url fn confluence-userlink" href="https://dled.atlassian.net/wiki/people/557058:abc">Dana</a>)

      result = Renderer.render(html, context(%{person_lookup: &author_named/1}))

      assert result.html =~ ~s(href="/people/557058%3Aabc")
      assert [%{kind: "internal", label: "Dana"}] = result.links
    end

    test "a person the mirror holds no page for keeps the link to the site" do
      html = ~s(<a href="/wiki/people/557058:nobody">Nobody</a>)

      assert Renderer.render(html, context(%{person_lookup: &author_named/1})).html =~
               ~s(href="https://dled.atlassian.net/wiki/people/557058:nobody")
    end

    test "a mention that already names this mirror is not sent back to the site" do
      html = ~s(<a href="/people/557058%3Aabc">Dana</a>)

      assert Renderer.render(html, context(%{person_lookup: &author_named/1})).html =~
               ~s(href="/people/557058%3Aabc")
    end

    # Confluence appends `?ref=confluence` to the mentions it writes, and the
    # address is still the person's page.
    test "a mention with the site's tracking query is the same person" do
      html =
        ~s(<a href="https://dled.atlassian.net/people/557058:abc?ref=confluence">Dana</a>)

      assert Renderer.render(html, context(%{person_lookup: &author_named/1})).html =~
               ~s(href="/people/557058%3Aabc")
    end

    defp author_named(account_id) when is_binary(account_id) do
      if account_id == "557058:abc", do: %{account_id: account_id}
    end
  end

  describe "a label in a body" do
    # The site spells a label page `/label/<name>` and the mirror draws that
    # catalogue itself, so the name is a link here whatever the label holds — an
    # empty catalogue is a true answer about this mirror.
    test "a label name is the mirror's catalogue" do
      assert Renderer.render(~s(<a href="/wiki/label/architecture">architecture</a>), context()).html =~
               ~s(href="/labels/architecture")
    end

    test "the plural spelling names the same catalogue" do
      assert Renderer.render(~s(<a href="/wiki/labels/my-label">my-label</a>), context()).html =~
               ~s(href="/labels/my-label")
    end

    # A label Confluence scoped to a space keeps the space in the address. The
    # catalogue is the label's either way — the mirror lists what it holds.
    test "a label scoped to a space is the same catalogue" do
      assert Renderer.render(~s(<a href="/wiki/label/MFS/runbook">runbook</a>), context()).html =~
               ~s(href="/labels/runbook")
    end

    test "a label link the mirror wrote itself is left alone" do
      assert Renderer.render(~s(<a href="/labels/architecture">architecture</a>), context()).html =~
               ~s(href="/labels/architecture")
    end

    test "a label address with a query names the same catalogue" do
      assert Renderer.render(
               ~s(<a href="/wiki/label/MFS/runbook?src=sidebar">runbook</a>),
               context()
             ).html =~
               ~s(href="/labels/runbook")
    end
  end

  describe "macros the site only draws for a signed-in reader" do
    test "an unknown-macro placeholder becomes a sentence, not a broken image" do
      # Confluence's placeholder is a picture served by the site under the
      # reader's session; copied into a mirror it is a broken image where a macro
      # was, and a blank box in a window that is not signed in.
      html =
        ~s(<img class="wysiwyg-unknown-macro" ) <>
          ~s(src="https://dled.atlassian.net/wiki/plugins/servlet/confluence/placeholder/unknown-macro?name=pageproperties&amp;locale=en_US&amp;version=2" />)

      rendered = Renderer.render(html, context()).html

      refute rendered =~ "<img"
      refute rendered =~ "unknown-macro"
      assert rendered =~ "mirror-macro-placeholder"
      assert rendered =~ "pageproperties"
    end

    test "an ordinary picture is still a picture" do
      html = ~s(<img src="https://example.test/photo.png" />)

      assert Renderer.render(html, context()).html =~ "https://example.test/photo.png"
    end

    test "a face points at the mirror, not at the site" do
      html =
        ~s(<img class="confluence-userlink" src="https://dled.atlassian.net/wiki/aa-avatar/557058:12861f68" />)

      result = Renderer.render(html, context())

      assert result.html =~ ~s(src="/people/557058%3A12861f68/avatar")
      refute result.html =~ "dled.atlassian.net"
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

    test "resolves another page's file when the mirror holds it" do
      # A download URL names the owner, and a page may link a file it does not
      # own; the lookup is the mirror's answer about content outside this page.
      with_lookup =
        context(%{
          attachment_lookup: fn
            999, "other.png" ->
              %{confluence_id: 9002, page_confluence_id: 999, space_key: "OPS"}

            _owner, _filename ->
              nil
          end
        })

      html = ~s(<a href="/wiki/download/attachments/999/other.png">other</a>)

      assert Renderer.render(html, with_lookup).html =~
               ~s(href="/attachments/OPS/999/9002/other.png")
    end

    test "leaves the link to the source when the mirror has no answer either" do
      with_lookup = context(%{attachment_lookup: fn _owner, _filename -> nil end})

      html = ~s(<a href="/wiki/download/attachments/999/other.png">other</a>)

      assert Renderer.render(html, with_lookup).html =~
               ~s(href="https://dled.atlassian.net/wiki/download/attachments/999/other.png")
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

      assert result.html =~ "The mirror does not draw this macro."
      assert result.html =~ "A Jira issues search"
      assert result.html =~ "original page"
    end

    test "the placeholder links back to the original page" do
      html = ~s(<ac:structured-macro ac:name="gadget"></ac:structured-macro>)

      assert Renderer.render(html, context(%{page: page()})).html =~
               ~s(href="#{page().external_url}")
    end

    # The editor stores the live search box as an empty macro — no query, no
    # scope — and the mirror draws it, so it must not reach the placeholder.
    test "a live search box is drawn by the mirror" do
      html = ~s(<ac:structured-macro ac:name="livesearch" ac:schema-version="1" />)

      rendered = Renderer.render(html, context(%{page: page()})).html

      assert rendered =~ ~s(data-macro="livesearch")
      refute rendered =~ "does not draw this macro"
    end

    test "an unknown macro is named as it is" do
      html = ~s(<ac:structured-macro ac:name="acme-widget"></ac:structured-macro>)

      assert Renderer.render(html, context()).html =~ "The acme-widget macro"
    end

    # Taken from what the editor really writes ("Macro capture 2026-11-06"):
    # the address is a reference whose own text is empty, so a reader that took
    # the text found no address and every widget connector from Confluence said
    # it named none.
    test "a widget connector's address is the reference it is stored as" do
      html = """
      <ac:structured-macro ac:name="widget">
        <ac:parameter ac:name="url"><ri:url ri:value="https://www.youtube.com/watch?v=ii1waoqualY" /></ac:parameter>
        <ac:parameter ac:name="width">600px</ac:parameter>
        <ac:parameter ac:name="height">300px</ac:parameter>
      </ac:structured-macro>
      """

      rendered = Renderer.render(html, context()).html

      assert rendered =~ ~s(data-url="https://www.youtube.com/watch?v=ii1waoqualY")
      # The size the editor records reaches the renderer as the page wrote it.
      assert rendered =~ ~s(data-height="300px")
      assert rendered =~ ~s(data-width="600px")
    end

    # Also from the capture page: a roadmap keeps its whole plan in one
    # URL-encoded parameter, so the marker has to carry it through untouched for
    # the timeline to be drawn from the page's own words.
    test "a roadmap's plan is read out of the parameter the editor writes" do
      html = """
      <ac:structured-macro ac:name="roadmap" ac:schema-version="1">
        <ac:parameter ac:name="timeline">true</ac:parameter>
        <ac:parameter ac:name="source">%7B%22title%22%3A%22Roadmap%20Planner%22%2C%22timeline%22%3A%7B%22startDate%22%3A%222026-11-06%2000%3A00%3A00%22%2C%22endDate%22%3A%222027-10-06%2000%3A00%3A00%22%2C%22displayOption%22%3A%22MONTH%22%7D%2C%22lanes%22%3A%5B%7B%22title%22%3A%22Lane%201%22%2C%22bars%22%3A%5B%7B%22title%22%3A%22Bar%201%22%2C%22startDate%22%3A%222026-11-01%2000%3A00%3A00%22%2C%22duration%22%3A2%7D%5D%7D%5D%7D</ac:parameter>
        <ac:parameter ac:name="title">Roadmap%20Planner</ac:parameter>
        <ac:parameter ac:name="hash">0beaea580d87d8054d0416dacb79faef</ac:parameter>
      </ac:structured-macro>
      """

      rendered = Renderer.render(html, context()).html

      assert rendered =~ ~s(data-macro="roadmap")

      # The whole plan travels in that one parameter, so it has to arrive whole:
      # the marker is where the renderer will read it from.
      assert %{"lanes" => [%{"title" => "Lane 1", "bars" => [%{"title" => "Bar 1"}]}]} =
               rendered |> source() |> URI.decode() |> Jason.decode!()
    end

    # Also from the capture page: a content tree writes its root as a link to a
    # page — `@home` for the space's top page — with the space key beside it and
    # the level the site folds open. Read as a title, `@home` found nothing, so
    # every tree a person inserted answered "the root is not in the mirror".
    test "a content tree keeps the root the editor writes" do
      html = """
      <ac:structured-macro ac:name="pagetree" ac:schema-version="1">
        <ac:parameter ac:name="root"><ac:link><ri:page ri:content-title="@home" /></ac:link></ac:parameter>
        <ac:parameter ac:name="spaces"><ri:space ri:space-key="MFS" /></ac:parameter>
        <ac:parameter ac:name="startDepth">1</ac:parameter>
      </ac:structured-macro>
      """

      rendered = Renderer.render(html, context()).html

      assert rendered =~ ~s(data-macro="pagetree")
      assert rendered =~ ~s(data-root="@home")
      assert rendered =~ ~s(data-spaces="MFS")
      assert rendered =~ ~s(data-start-depth="1")
    end

    test "a macro nobody can draw keeps the body a reader came for" do
      html = """
      <ac:structured-macro ac:name="confiform-table">
        <ac:parameter ac:name="formName">Holidays</ac:parameter>
        <ac:rich-text-body><p>The holiday calendar lives here.</p></ac:rich-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ "The mirror does not draw this macro."
      assert result.html =~ "ConfiForms table"
      assert result.html =~ "The holiday calendar lives here."
    end

    # A chart, a diagram, a timeline: the author's content is the macro's own
    # text, and a box that only says "not drawn" drops the one thing a reader
    # came for. The words come first, the apology second.
    test "a macro whose content is its own text shows that text first" do
      html = """
      <ac:structured-macro ac:name="chart">
        <ac:parameter ac:name="type">pie</ac:parameter>
        <ac:plain-text-body><![CDATA[{"series": [{"name": "Open", "value": 3}]}]]></ac:plain-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~
               ~r{<blockquote class="mirror-macro-placeholder"><pre class="mirror-macro-source">.*series.*</pre><p>The mirror does not draw this macro\.</p>}s
    end

    # The shape a real page arrives in: the export view kept a picture of the
    # macro and nothing else, and the content lives in the storage.
    test "a macro the export reduced to a picture still shows what it carried" do
      storage = """
      <ac:structured-macro ac:name="drawio">
        <ac:plain-text-body><![CDATA[<mxGraphModel><root/></mxGraphModel>]]></ac:plain-text-body>
      </ac:structured-macro>
      """

      html =
        ~s(<img class="wysiwyg-unknown-macro" src="https://dled.atlassian.net/wiki/plugins/servlet/placeholder/unknown-macro?name=drawio">)

      result = Renderer.render(html, context(%{storage: storage}))

      assert result.html =~ "mxGraphModel"
      assert result.html =~ "The mirror does not draw this macro."
    end

    test "an excerpt keeps its words, wrapped the way the export view wraps one" do
      # The body *is* the answer, so there is nothing to draw and nothing to
      # explain. The wrapper is what an excerpt include on another page reads.
      html = """
      <ac:structured-macro ac:name="excerpt">
        <ac:rich-text-body><p>A read-only cache.</p></ac:rich-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ ~s(<div class="excerpt-macro"><p>A read-only cache.</p></div>)
      refute result.html =~ "does not draw this macro"
    end

    test "an information panel keeps the classes that make it a panel" do
      # export_view renders a tip/note/warning macro as a div family, and it is
      # the classes alone that carry the meaning: strip them and the panel
      # degrades to the bare sentence inside it. The stylesheet draws the box,
      # the tone and the badge from these names.
      html =
        ~s(<div class="confluence-information-macro confluence-information-macro-tip">) <>
          ~s(<span class="aui-icon aui-icon-small aui-iconfont-approve confluence-information-macro-icon"></span>) <>
          ~s(<div class="confluence-information-macro-body"><p>Read this first.</p></div></div>)

      result =
        Renderer.render(
          html,
          Map.put(
            context(),
            :storage,
            ~s(<ac:structured-macro ac:name="tip"></ac:structured-macro>)
          )
        )

      assert result.html =~
               ~s(class="confluence-information-macro confluence-information-macro-tip")

      assert result.html =~ ~s(class="confluence-information-macro-body")
      assert result.html =~ "Read this first."
    end

    # Confluence keeps pasted markup in a page's storage but draws the page from
    # the editor's document, where that markup is prose. A mirror that trusts
    # export_view draws a panel the site never showed.
    @pasted_chrome ~s(<p>Before.</p><div class="panel"><div class="panelContent"><p>Pasted panel.</p></div></div>)

    test "chrome the page does not declare is unwrapped, and its words are kept" do
      result = Renderer.render(@pasted_chrome, Map.put(context(), :storage, "<p>Before.</p>"))

      refute result.html =~ ~s(class="panel)
      refute result.html =~ "panelContent"
      assert result.html =~ "<p>Pasted panel.</p>"
    end

    test "the words of unwrapped chrome stay searchable" do
      result = Renderer.render(@pasted_chrome, Map.put(context(), :storage, "<p>Before.</p>"))

      assert result.text =~ "Pasted panel."
    end

    test "chrome is earned by a declaration of the macro that draws it" do
      storage = ~s(<ac:structured-macro ac:name="panel"></ac:structured-macro>)

      result = Renderer.render(@pasted_chrome, Map.put(context(), :storage, storage))

      assert result.html =~ ~s(class="panel")
    end

    test "a panel the editor stored as an ADF node is a declaration too" do
      # The modern palette writes a panel as an ADF node, not a structured macro,
      # and Confluence draws it. Counting only structured macros would strip a
      # panel the original really shows.
      storage = """
      <ac:adf-extension><ac:adf-node type="panel">
        <ac:adf-attribute key="panel-type">note</ac:adf-attribute>
        <ac:adf-content><p>A real panel.</p></ac:adf-content>
      </ac:adf-node></ac:adf-extension>
      """

      result = Renderer.render(@pasted_chrome, Map.put(context(), :storage, storage))

      assert result.html =~ ~s(class="panel)
    end

    test "chrome is earned one block per declaration, in reading order" do
      html = ~s(<div class="panel"><p>First.</p></div><div class="panel"><p>Second.</p></div>)
      storage = ~s(<ac:structured-macro ac:name="panel"></ac:structured-macro>)

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ ~s(<div class="panel"><p>First.</p></div>)
      refute result.html =~ ~s(<div class="panel"><p>Second.)
      assert result.html =~ "Second."
    end

    # A two-column layout is the one piece of macro chrome that is *structure*
    # rather than decoration: the site's export keeps the wrapper, the row and
    # each column's own width, and the stylesheet draws them side by side. It is
    # chrome all the same, so it is earned the same way.
    @columns ~s(<div class="sectionColumnWrapper"><div class="sectionMacroWithBorder"><div class="sectionMacroRow"><div class="columnMacro" style="width:50%;min-width:50%;max-width:50%;"><p>Left column</p></div><div class="columnMacro" style="width:50%;min-width:50%;max-width:50%;"><p>Right column</p></div></div></div></div>)

    test "a section the storage declares keeps its columns and their widths" do
      storage = """
      <ac:structured-macro ac:name="section">
        <ac:parameter ac:name="border">true</ac:parameter>
        <ac:rich-text-body>
          <ac:structured-macro ac:name="column"><ac:parameter ac:name="width">50%</ac:parameter></ac:structured-macro>
          <ac:structured-macro ac:name="column"><ac:parameter ac:name="width">50%</ac:parameter></ac:structured-macro>
        </ac:rich-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(@columns, Map.put(context(), :storage, storage))

      assert result.html =~ ~s(class="sectionMacroRow")
      assert result.html =~ "width:50%"
      assert result.html =~ "<p>Left column</p>"
      assert result.html =~ "<p>Right column</p>"
    end

    test "a layout pasted into the storage as prose loses its columns and keeps its words" do
      result = Renderer.render(@columns, Map.put(context(), :storage, "<p>Before.</p>"))

      refute result.html =~ "sectionColumnWrapper"
      refute result.html =~ "columnMacro"
      assert result.html =~ "<p>Left column</p>"
      assert result.html =~ "<p>Right column</p>"
    end

    # The editor that inserted a two-column layout in 2026 stores bands of cells,
    # not the `section` macro above, and serves them as `columnLayout` divs whose
    # class names the shape (`two-equal`). Taken from what `export_view` returned
    # for that page once it was published.
    test "a two-column layout from the new editor keeps its two columns" do
      html = """
      <div class="contentLayout2">
        <div class="columnLayout fixed-width" data-layout="fixed-width"><div class="cell normal" data-type="normal"><div class="innerCell"><p>Above the layout.</p></div></div></div>
        <div class="columnLayout two-equal" data-layout="two-equal"><div class="cell normal" data-type="normal"><div class="innerCell"><p>Left column</p></div></div><div class="cell normal" data-type="normal"><div class="innerCell"><p>Right column</p></div></div></div>
      </div>
      """

      result = Renderer.render(html, context())

      assert result.html =~ ~s(class="columnLayout two-equal")
      assert result.html =~ "<p>Above the layout.</p>"
      assert result.html =~ "<p>Left column</p>"
      assert result.html =~ "<p>Right column</p>"
    end

    test "a panel draws the icon its storage declares, which the export view drops" do
      html =
        ~s(<div class="panel" style="background-color: #EAE6FF;"><div class="panelContent"><p>An aside.</p></div></div>)

      storage = """
      <ac:structured-macro ac:name="panel">
        <ac:parameter ac:name="panelIcon">:check_mark:</ac:parameter>
        <ac:parameter ac:name="panelIconId">atlassian-check_mark</ac:parameter>
      </ac:structured-macro>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ ~s(<span class="mirror-panel-icon">✅</span>)
      # Inside the panel's body, where Confluence puts it, not beside the panel.
      assert result.html =~ ~r{<div class="panelContent"[^>]*><p><span class="mirror-panel-icon">}
    end

    # A sibling `<span>` before the body's first paragraph is the body's first
    # child, so the margin rule meant for the paragraph misses it: the words sit
    # one line lower and the card is taller than the panel beside it.
    test "a panel's icon reads with its first words, not above them" do
      html =
        ~s(<div class="panel" style="background-color: #EAE6FF;"><div class="panelContent"><p>An aside.</p></div></div>)

      storage = """
      <ac:structured-macro ac:name="panel">
        <ac:parameter ac:name="panelIconId">1f308</ac:parameter>
      </ac:structured-macro>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ ~r{<p><span class="mirror-panel-icon">🌈</span>An aside\.</p>}
      refute result.html =~ ~r{<div class="panelContent"[^>]*><span class="mirror-panel-icon">}
    end

    # Two icons on one card is not what the site shows: a panel that declares a
    # glyph draws that glyph *instead of* the badge the mirror draws for a typed
    # panel. The class is how the stylesheet knows to drop the badge.
    test "a panel with its own glyph is marked, so the badge is not drawn beside it" do
      html =
        ~s(<div class="panel" style="background-color: #E6FCFF;"><div class="panelContent"><p>An aside.</p></div></div>)

      storage = """
      <ac:structured-macro ac:name="panel">
        <ac:parameter ac:name="panelIconId">1f308</ac:parameter>
      </ac:structured-macro>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ ~r{<div class="panel[^"]*mirror-panel-iconic[^"]*"}
    end

    test "a typed panel declares no glyph, so it keeps the badge" do
      html =
        ~s(<div class="panel confluence-information-macro confluence-information-macro-note"><div class="panelContent"><p>An aside.</p></div></div>)

      storage = """
      <ac:adf-extension><ac:adf-node type="panel">
        <ac:adf-attribute key="panel-type">note</ac:adf-attribute>
        <ac:adf-content><p>An aside.</p></ac:adf-content>
      </ac:adf-node></ac:adf-extension>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      refute result.html =~ "mirror-panel-iconic"
    end

    # The storage's panels and the export's panels meet by order, and a classic
    # `panel` macro takes its turn. Without that, the first ADF kind was handed
    # to whichever panel came first in the body — an author's coloured panel
    # drew itself as a purple note, badge and all.
    test "a classic panel before a typed one keeps the colour the author gave it" do
      html = """
      <div class="panel" style="background-color: #E6FCFF;border-width: 1px;"><div class="panelContent"><p>Coloured.</p></div></div>
      <div class="panel"><div class="panelContent"><p>Typed.</p></div></div>
      """

      storage = """
      <ac:structured-macro ac:name="panel">
        <ac:parameter ac:name="panelIconId">1f308</ac:parameter>
      </ac:structured-macro>
      <ac:adf-extension><ac:adf-node type="panel">
        <ac:adf-attribute key="panel-type">note</ac:adf-attribute>
        <ac:adf-content><p>Typed.</p></ac:adf-content>
      </ac:adf-node></ac:adf-extension>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      [first, second] =
        Regex.split(~r{<div class="panel(?=[\s">])}, result.html, parts: 3) |> tl()

      refute first =~ "confluence-information-macro-note"
      assert second =~ "confluence-information-macro-note"
    end

    test "a panel the editor typed is drawn as an information macro of that kind" do
      # The modern palette stores a panel as an ADF node that names its kind.
      # Confluence draws that kind's tone and badge; the export view carries
      # neither, so the panel is drawn with the vocabulary that already exists.
      html =
        ~s(<div class="panel" style="background-color: #EAE6FF;"><div class="panelContent"><p>An aside.</p></div></div>)

      storage = """
      <ac:adf-extension><ac:adf-node type="panel">
        <ac:adf-attribute key="panel-type">note</ac:adf-attribute>
        <ac:adf-content><p>An aside.</p></ac:adf-content>
      </ac:adf-node></ac:adf-extension>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ "confluence-information-macro-note"
      assert result.html =~ ~s(<span class="confluence-information-macro-icon"></span>)
    end

    test "a panel with no declared icon is drawn without one" do
      html = ~s(<div class="panel"><div class="panelContent"><p>Plain.</p></div></div>)
      storage = ~s(<ac:structured-macro ac:name="panel"></ac:structured-macro>)

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ ~s(class="panel")
      refute result.html =~ "mirror-panel-icon"
    end

    test "an icon belongs to the panel that declared it, in reading order" do
      html =
        ~s(<div class="panel"><div class="panelContent"><p>First.</p></div></div><div class="panel"><div class="panelContent"><p>Second.</p></div></div>)

      storage = """
      <ac:structured-macro ac:name="panel">
        <ac:parameter ac:name="panelIconId">1f308</ac:parameter>
      </ac:structured-macro>
      <ac:structured-macro ac:name="panel"></ac:structured-macro>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      [first, second] =
        Regex.split(~r{<div class="panel(?=[\s">])}, result.html, parts: 3) |> tl()

      assert first =~ "mirror-panel-icon"
      assert first =~ "🌈"
      refute second =~ "mirror-panel-icon"
    end

    test "chrome is left alone when there is no storage to judge it by" do
      result = Renderer.render(@pasted_chrome, context())

      assert result.html =~ ~s(class="panel")
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
      refute result.html =~ "does not draw this macro"
    end

    test "a parameter that names a page carries the page's title, not nothing" do
      # Confluence writes the include's target as a typed value with no name of
      # its own: `<ac:parameter ac:name=""><ri:page ri:content-title="…"/></ac:parameter>`.
      # Read only for its text, that parameter is empty and the macro names no page.
      html = """
      <ac:structured-macro ac:name="include">
        <ac:parameter ac:name=""><ri:page ri:content-title="Architecture Overview" /></ac:parameter>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ ~s(data-macro="include")
      assert result.html =~ ~s(data-page="Architecture Overview")
    end

    test "a named parameter that holds a reference keeps its own word" do
      html = """
      <ac:structured-macro ac:name="user-profile">
        <ac:parameter ac:name="user"><ri:user ri:account-id="557058:abc" /></ac:parameter>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ ~s(data-macro="user-profile")
      assert result.html =~ ~s(data-user="557058:abc")
    end

    test "an html macro is the markup it holds, shown through the sanitiser" do
      html = """
      <ac:structured-macro ac:name="html">
        <ac:plain-text-body><![CDATA[<p class="note">raw <b>html</b></p><script>alert(1)</script>]]></ac:plain-text-body>
      </ac:structured-macro>
      """

      result = Renderer.render(html, context())

      assert result.html =~ ~s(<p class="note">raw <b>html</b></p>)
      refute result.html =~ "<script"
      refute result.html =~ "does not draw this macro"
    end

    test "an html macro the export only pictures is drawn from its storage" do
      # What the site actually sends: no macro element at all, a picture of one.
      html = """
      <p>before</p>
      <img class="wysiwyg-unknown-macro" src="/wiki/plugins/servlet/confluence/placeholder/unknown-macro?name=html" />
      <p>after</p>
      """

      storage = """
      <ac:structured-macro ac:name="html"><ac:plain-text-body><![CDATA[<p>raw <b>html</b></p>]]></ac:plain-text-body></ac:structured-macro>
      """

      result = Renderer.render(html, Map.put(context(), :storage, storage))

      assert result.html =~ "<p>raw <b>html</b></p>"
      refute result.html =~ "does not draw this macro"
      refute result.html =~ "unknown-macro"
    end

    test "a macro the mirror cannot draw is named in words a reader knows" do
      # The widget used to say "The tasks-report macro" — the key rather than the
      # thing — because the label map knew a spelling Confluence does not store.
      # That macro is drawn now, so the claim is pinned on one that still is not.
      html = """
      <img class="wysiwyg-unknown-macro" src="/wiki/plugins/servlet/confluence/placeholder/unknown-macro?name=jira" />
      """

      result = Renderer.render(html, context())

      assert result.html =~ "A Jira issues search"
      refute result.html =~ "the jira macro"
    end

    test "a code block that asks for a gutter gets its line numbers" do
      # The code macro's own `gutter` setting survives in the export view, so the
      # mirror honours the author's choice rather than making one.
      html =
        ~s(<div class="code panel"><div class="codeContent panelContent">) <>
          ~s(<pre class="syntaxhighlighter-pre" data-syntaxhighlighter-params="brush: sql; gutter: true; theme: Confluence">) <>
          "SELECT 1;\nFROM dual;\nWHERE 1 = 1;</pre></div></div>"

      result = Renderer.render(html, context())

      assert result.html =~ ~s(class="mirror-code")
      assert gutter(result.html) == ["1", "2", "3"]
    end

    test "a code block without one keeps its plain pre" do
      html =
        ~s(<div class="code panel"><div class="codeContent panelContent">) <>
          ~s(<pre class="syntaxhighlighter-pre" data-syntaxhighlighter-params="brush: sql; gutter: false; theme: Confluence">) <>
          "SELECT 1;</pre></div></div>"

      result = Renderer.render(html, context())

      assert result.html =~ "syntaxhighlighter-pre"
      refute result.html =~ "mirror-code-gutter"
    end
  end

  defp gutter(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("pre.mirror-code-gutter")
    |> Floki.text()
    |> String.split("\n")
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

    test "an emoji Confluence escaped instead of writing it is still the character" do
      html = """
      <p>Meeting <img class="emoticon emoticon-blue-star" data-emoji-shortname=":calendar_spiral:"
                      data-emoji-id="1f5d3" data-emoji-fallback="\\uD83D\\uDDD3"
                      src="https://dled.atlassian.net/wiki/images/icons/emoticons/star_blue.png" /></p>
      """

      result = Renderer.render(html, context())

      assert result.html =~ "Meeting 🗓"
      assert result.text =~ "🗓"
      refute result.html =~ "\\u"
    end

    test "an image it cannot name stays an image" do
      html =
        ~s(<p>Odd <img class="transform-error" src="https://dled.atlassian.net/placeholder/error" /></p>)

      assert Renderer.render(html, context()).html =~ "<img"
    end

    test "a character Confluence stored as an escape reaches the reader and the index" do
      html = "<h2>\\uD83E\\uDD14 Problem statement</h2>"

      result = Renderer.render(html, context())

      assert result.html =~ "🤔 Problem statement"
      assert result.text =~ "🤔"
      refute result.html =~ "\\u"
    end
  end

  describe "cell colours" do
    test "a cell keeps the colour Confluence gave it, for the stylesheet to paint" do
      html =
        ~s(<table><tbody><tr><td data-highlight-colour="#e3fcef">Must have:</td></tr></tbody></table>)

      assert Renderer.render(html, context()).html =~ ~s(data-highlight-colour="#e3fcef")
    end
  end

  describe "ADF repair" do
    test "a decision keeps the state its export view dropped" do
      html = ~s(<ul class="decision-list"><li>Ship it.</li></ul>)

      storage =
        ~s(<ac:adf-node type="decision-list"><ac:adf-node type="decision-item"><ac:adf-attribute key="state">DECIDED</ac:adf-attribute><ac:adf-content>Ship it.</ac:adf-content></ac:adf-node></ac:adf-node>)

      assert Renderer.render(html, context(%{storage: storage})).html =~
               ~s(<li data-decision-state="decided">Ship it.</li>)
    end
  end

  describe "a macro that arrives as a picture of itself" do
    test "is rebuilt as the marker its storage declaration describes" do
      html =
        ~s(<img class="wysiwyg-unknown-macro" src="/wiki/plugins/servlet/confluence/placeholder/unknown-macro?name=native-embed:whiteboard&amp;locale=en_US" />)

      storage =
        ~s(<ac:structured-macro ac:name="native-embed:whiteboard"><ac:parameter ac:name="url">https://site/wiki/spaces/MFS/whiteboard/1</ac:parameter></ac:structured-macro>)

      result = Renderer.render(html, context(%{storage: storage}))

      assert result.html =~ ~s(data-macro="native-embed:whiteboard")
      assert result.html =~ ~s(data-url="https://site/wiki/spaces/MFS/whiteboard/1")
      refute result.html =~ "does not draw this macro"
    end

    test "a macro the mirror cannot draw still becomes the widget" do
      html =
        ~s(<img class="wysiwyg-unknown-macro" src="/wiki/plugins/servlet/confluence/placeholder/unknown-macro?name=table-filter" />)

      assert Renderer.render(html, context()).html =~ "does not draw this macro"
    end

    test "a declaration nested inside another macro still gives up its parameters" do
      html =
        ~s(<img class="wysiwyg-unknown-macro" src="/wiki/plugins/servlet/confluence/placeholder/unknown-macro?name=native-embed:whiteboard" />)

      storage =
        ~s(<ac:structured-macro ac:name="excerpt"><ac:rich-text-body><ac:structured-macro ac:name="native-embed:whiteboard"><ac:parameter ac:name="url">https://site/wiki/spaces/MFS/whiteboard/7</ac:parameter></ac:structured-macro></ac:rich-text-body></ac:structured-macro>)

      assert Renderer.render(html, context(%{storage: storage})).html =~
               ~s(data-url="https://site/wiki/spaces/MFS/whiteboard/7")
    end
  end
end
