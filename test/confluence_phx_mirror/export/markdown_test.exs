defmodule ConfluencePhxMirror.Export.MarkdownTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Export.Markdown

  @ctx %{
    page_files: %{1003 => "Space/Macros/Macros.md"},
    current_folder: "Space/Page",
    attachments: %{"/attachments/ENG/1002/9001/diagram.svg" => "attachments/diagram.svg"}
  }

  test "converts headings, emphasis and inline code" do
    md =
      Markdown.from_html(
        "<h2>Overview</h2><p>Some <strong>bold</strong> and <code>x</code>.</p>",
        @ctx
      )

    assert md =~ "## Overview"
    assert md =~ "Some **bold** and `x`."
  end

  test "keeps links inside the export relative" do
    md = Markdown.from_html(~s(<p><a href="/spaces/ENG/pages/1003/macros">macros</a></p>), @ctx)

    assert md =~ "[macros](../Macros/Macros.md)"
  end

  # A link that names a heading is a place in a document, and a zip holds
  # documents: the fragment survives the path, as it does in the mirror.
  test "keeps the place a link names in another page" do
    md =
      Markdown.from_html(
        ~s(<p><a href="/spaces/ENG/pages/1003/macros#Overview">macros</a></p>),
        @ctx
      )

    assert md =~ "[macros](../Macros/Macros.md#Overview)"
  end

  test "keeps an anchor inside the page" do
    md = Markdown.from_html(~s(<p><a href="#Overview">top</a></p>), @ctx)

    assert md =~ "[top](#Overview)"
  end

  describe "a link the zip has no file for" do
    setup do
      ctx =
        Map.put(@ctx, :source_url, "https://demo.atlassian.net/wiki/spaces/ENG/pages/1002/Arch")

      {:ok, ctx: ctx}
    end

    # A mirror path is an address on a server, and a zip has none: left as it is,
    # the reader gets a dead link. The site's own address for the same thing is
    # what the sync rewrote, so the export gives it back.
    test "a person's page is the site's address again", %{ctx: ctx} do
      md = Markdown.from_html(~s(<p><a href="/people/557058%3Aabc">Dana</a></p>), ctx)

      assert md =~ "[Dana](https://demo.atlassian.net/wiki/people/557058%3Aabc)"
    end

    test "a label is the site's address again", %{ctx: ctx} do
      md = Markdown.from_html(~s(<p><a href="/labels/runbook">runbook</a></p>), ctx)

      assert md =~ "[runbook](https://demo.atlassian.net/wiki/label/runbook)"
    end

    test "a page the archive does not carry is the site's address again", %{ctx: ctx} do
      md = Markdown.from_html(~s(<p><a href="/spaces/ENG/pages/999/Hidden">Hidden</a></p>), ctx)

      assert md =~ "[Hidden](https://demo.atlassian.net/wiki/spaces/ENG/pages/999/Hidden)"
    end

    test "with no site to name, the words stay and the link goes" do
      md = Markdown.from_html(~s(<p><a href="/people/557058%3Aabc">Dana</a></p>), @ctx)

      assert md =~ "Dana"
      refute md =~ "]("
    end
  end

  test "rewrites attachment links and images to the page folder" do
    md =
      Markdown.from_html(
        ~s(<p><img src="/attachments/ENG/1002/9001/diagram.svg" alt="Diagram" /></p>),
        @ctx
      )

    assert md =~ "![Diagram](attachments/diagram.svg)"
  end

  test "renders nested lists with indentation" do
    md = Markdown.from_html("<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>", @ctx)

    assert md =~ "- One"
    assert md =~ "- Two"
    assert md =~ "  - Nested"
  end

  test "renders code blocks with their Confluence brush" do
    md =
      Markdown.from_html(
        ~s(<pre class="syntaxhighlighter-pre" data-syntaxhighlighter-params="brush: sql; gutter: false">SELECT 1;</pre>),
        @ctx
      )

    assert md =~ "```sql"
    assert md =~ "SELECT 1;"
  end

  test "renders tables as pipe tables" do
    md =
      Markdown.from_html(
        "<table><tbody><tr><th>Key</th><th>Value</th></tr><tr><td>a</td><td>b</td></tr></tbody></table>",
        @ctx
      )

    assert md =~ "| Key | Value |"
    assert md =~ "| --- | --- |"
    assert md =~ "| a | b |"
  end

  test "keeps expand macro text instead of dropping it" do
    md =
      Markdown.from_html(
        ~s(<details><summary>Why?</summary><p>Because.</p></details>),
        @ctx
      )

    assert md =~ "**Why?**"
    assert md =~ "Because."
  end

  # A widget connector is somebody else's page in a frame, with its address kept
  # under it. A `.md` file cannot carry a frame, so the tag goes — and the
  # address, which the renderer puts under every frame, is what a reader of the
  # export keeps.
  test "a widget's frame goes and the address under it stays a link" do
    md =
      Markdown.from_html(
        """
        <iframe class="mirror-embed" src="https://www.youtube.com/embed/abc"></iframe>
        <p class="mirror-embed-source mirror-embed-address"><a href="https://www.youtube.com/watch?v=abc">https://www.youtube.com/watch?v=abc</a></p>
        """,
        @ctx
      )

    refute md =~ "iframe"

    assert md =~
             "[https://www.youtube.com/watch?v=abc](https://www.youtube.com/watch?v=abc)"
  end

  # The macros resolve to HTML at sync time, so the Markdown export reads that
  # HTML like any other — but only if the shapes the renderers chose convert.
  # These three are the shapes that matter: a tab, a listing and a placeholder.
  describe "macro output" do
    test "a tab becomes its summary in bold with the tab's content under it" do
      md =
        Markdown.from_html(
          ~s(<div class="mirror-aura-tabs"><details class="mirror-aura-tab" open="open"><summary>Install</summary><p>Run mix setup.</p></details></div>),
          @ctx
        )

      assert md =~ "**Install**"
      assert md =~ "Run mix setup."
    end

    test "a generated listing stays a list a reader can follow" do
      md =
        Markdown.from_html(
          ~s(<p class="mirror-dynamic-heading">Child pages</p><ul class="mirror-dynamic-list"><li><a href="/spaces/ENG/pages/1003/macros">Macros</a></li></ul>),
          @ctx
        )

      assert md =~ "Child pages"
      assert md =~ "- [Macros](../Macros/Macros.md)"
    end

    test "an undrawn macro reads as a note, not as prose" do
      md =
        Markdown.from_html(
          ~s(<blockquote class="mirror-macro-placeholder"><p>The mirror does not draw this macro.</p><p>Appfire's table filter.</p></blockquote><p>The table follows.</p>),
          @ctx
        )

      assert md =~ "> The mirror does not draw this macro."
      assert md =~ "> Appfire's table filter."
      assert md =~ "The table follows."
    end
  end

  describe "a drawing and its decoration" do
    # A roadmap is drawn from the plan's own document, and its picture is made of
    # positioned boxes — which a text export cannot carry. What a reader of the
    # Markdown needs is what the picture says: the range, the lanes, the bars.
    test "a roadmap keeps its range, its lanes and its bars" do
      md =
        Markdown.from_html(
          ~s(<figure class="mirror-roadmap"><figcaption class="mirror-roadmap-range">Nov 2026 – Oct 2027</figcaption><div class="mirror-roadmap-grid"><p aria-hidden="true"></p><p class="mirror-roadmap-months" aria-hidden="true"><span>Nov</span><span>Dec</span></p><p class="mirror-roadmap-lane-title">Lane 1</p><div class="mirror-roadmap-track"><span class="mirror-roadmap-bar">Bar 1</span></div></div></figure>),
          @ctx
        )

      assert md =~ "Nov 2026 – Oct 2027"
      assert md =~ "Lane 1"
      assert md =~ "Bar 1"
      # The months across the top are the picture's scale, hidden from a screen
      # reader, so they are hidden from a text export too.
      refute md =~ "NovDec"
    end

    # The gutter of a numbered code block is a column of digits drawn beside the
    # code, and `aria-hidden` says so. Copied into Markdown it made the export
    # read "1\n2\n3" and then the code.
    test "a column drawn beside the text is not part of the text" do
      md =
        Markdown.from_html(
          ~s(<div class="mirror-code"><pre class="mirror-code-gutter" aria-hidden="true">1\n2</pre><pre class="syntaxhighlighter-pre">a\nb</pre></div>),
          @ctx
        )

      refute md =~ "1\n2"
      assert md =~ "a\nb"
    end
  end
end
