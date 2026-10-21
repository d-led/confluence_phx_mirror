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
end
