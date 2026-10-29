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
end
