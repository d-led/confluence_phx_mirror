defmodule ConfluencePhxMirror.Mcp.MarkdownTest do
  @moduledoc """
  The conversion cache: a page's exported body is converted once, and a body the
  sync replaced is converted again. Entries are shared across the suite (the
  cache outlives a sandbox rollback), so every test here builds content of its
  own instead of reusing the demo pages.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mcp.Markdown
  alias ConfluencePhxMirror.Mirror

  test "a rendered body is kept for the next call" do
    page = unique_page("Held for the next call")

    refute Markdown.cached?(page)

    assert Markdown.page(page) =~ "Held for the next call"
    assert Markdown.cached?(page)
  end

  test "two calls answer with the same Markdown" do
    page = unique_page("Same both times")

    assert Markdown.page(page) == Markdown.page(page)
  end

  test "a body the sync replaced is converted again, not answered from the old entry" do
    page = unique_page("Before the sync")
    assert Markdown.page(page) =~ "Before the sync"

    {:ok, _} = Mirror.update_rendered(page, %{body_export: "<p>After the sync</p>"})
    {:ok, reloaded} = Mirror.find_page(page.confluence_id)

    markdown = Markdown.page(reloaded)

    assert markdown =~ "After the sync"
    refute markdown =~ "Before the sync"
  end

  test "a comment's body is converted as Markdown too" do
    comment = %ConfluencePhxMirror.Mirror.Comment{
      id: -System.unique_integer([:positive]),
      body_export: "<p>One <strong>bold</strong> reply</p>"
    }

    assert Markdown.comment(comment) =~ "One **bold** reply"
  end

  defp unique_page(heading) do
    space = space_fixture()
    id = System.unique_integer([:positive])

    page_fixture(space, %{
      confluence_id: id,
      title: "Cache #{id}",
      body_export: "<h2>#{heading} #{id}</h2><p>Body text.</p>"
    })
  end
end
