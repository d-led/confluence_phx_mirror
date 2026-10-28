defmodule ConfluencePhxMirror.Sync.DynamicContent.IncludeTest do
  @moduledoc """
  *Include Page* and *Excerpt Include*: another page's words, inside this one.

  Two promises are worth pinning. The body is expanded **as the page it came
  from** — an included table of contents lists the included headings — and an
  include that loops stops instead of expanding for ever, because a ring of two
  pages is easy to write in Confluence and nothing there refuses it.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Getting Started", space: @space}

  describe "include" do
    test "puts the named page's body where the marker is" do
      StubContent.script(
        page_by_title: {:ok, page(2, "Architecture Overview", "<p>The pipeline.</p>")}
      )

      html = expand(include_macro("Architecture Overview"))

      assert html =~ "<p>The pipeline.</p>"
      assert StubContent.questions() == [{:page_by_title, "Architecture Overview"}]
    end

    test "expands the included body as the page it came from" do
      included =
        page(
          2,
          "Architecture",
          ~s(<h2 id="poll">Poll</h2><div class="mirror-macro" data-macro="toc"></div>)
        )

      StubContent.script(page_by_title: {:ok, included})

      html = expand(~s(<h2 id="host">Host heading</h2>#{include_macro("Architecture")}))

      assert html =~ ~s(href="#poll")
      refute html =~ ~s(href="#host")
    end

    test "a page that includes itself is stopped, not expanded" do
      StubContent.script(
        page_by_title: {:ok, page(1, "Getting Started", include_macro("Getting Started"))}
      )

      assert text(expand(include_macro("Getting Started"))) =~
               "This page includes itself here"
    end

    test "a ring of two pages stops at the page it has already read" do
      StubContent.script(
        page_by_title: fn
          "A" -> {:ok, page(2, "A", include_macro("B"))}
          "B" -> {:ok, page(3, "B", include_macro("A"))}
        end
      )

      assert text(expand(include_macro("A"))) =~ "includes itself here"
    end

    test "a chain longer than the budget is stopped too" do
      StubContent.script(
        page_by_title: fn "Chain " <> number ->
          next = String.to_integer(number) + 1
          {:ok, page(200 + next, "Chain #{next}", include_macro("Chain #{next}"))}
        end
      )

      assert text(expand(include_macro("Chain 2"))) =~ "included too deeply"
    end

    test "a page the port will not answer for is said out loud" do
      StubContent.script(page_by_title: :error)

      assert text(expand(include_macro("Secret Notes"))) =~
               "not in the mirror, or not readable here"
    end

    test "a macro that names no page says so" do
      assert text(expand(~s(<div class="mirror-macro" data-macro="include"></div>))) =~
               "names no page"
    end
  end

  describe "excerpt-include" do
    test "includes the excerpt region, not the whole page" do
      body =
        ~s(<div class="excerpt-macro"><p>A read-only cache.</p></div><h2 id="overview">Overview</h2>)

      StubContent.script(page_by_title: {:ok, page(2, "Architecture Overview", body)})

      html = expand(excerpt_macro("Architecture Overview"))

      assert html =~ "A read-only cache."
      # The page's own heading stayed behind with the rest of its body.
      assert html |> Floki.parse_fragment!() |> Floki.find("h2") == []
      refute html =~ "excerpt-macro"
    end

    test "expands a macro inside the excerpt as the page that wrote it" do
      body =
        ~s(<div class="excerpt-macro"><h3 id="detail">Detail</h3><div class="mirror-macro" data-macro="toc"></div></div>)

      StubContent.script(page_by_title: {:ok, page(2, "Architecture", body)})

      assert expand(excerpt_macro("Architecture")) =~ ~s(href="#detail")
    end

    test "a page that declares no excerpt says so" do
      StubContent.script(page_by_title: {:ok, page(2, "Architecture", "<p>Whole body.</p>")})

      html = expand(excerpt_macro("Architecture"))

      assert text(html) =~ "declares no excerpt"
      refute html =~ "Whole body."
    end
  end

  defp expand(marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp include_macro(title),
    do: ~s(<div class="mirror-macro" data-macro="include" data-page="#{title}"></div>)

  defp excerpt_macro(title),
    do: ~s(<div class="mirror-macro" data-macro="excerpt-include" data-page="#{title}"></div>)

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp page(id, title, body) do
    %{
      id: id,
      confluence_id: 1000 + id,
      title: title,
      slug: ConfluencePhxMirror.Mirror.Page.slugify(title),
      type: "page",
      space: @space,
      body_export: body
    }
  end
end
