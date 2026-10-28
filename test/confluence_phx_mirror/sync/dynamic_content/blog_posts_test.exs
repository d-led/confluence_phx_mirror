defmodule ConfluencePhxMirror.Sync.DynamicContent.BlogPostsTest do
  @moduledoc """
  *Blog Posts* asks the mirror the question *Recently Updated* asks, with one
  word changed — a different type and a different order.

  The query is the specification: a post list that quietly included pages would
  look right and be wrong.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="blog-posts"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    StubContent.script(search: {:ok, [page(2, "Release 2.0"), page(3, "Week 42")]})
  end

  test "lists the posts the port answers, newest first" do
    assert titles(expand()) == ["Release 2.0", "Week 42"]
  end

  test "asks for posts only, by creation" do
    expand()

    assert asked() == "type = blogpost order by created desc limit 5"
  end

  test "narrows to the spaces and labels the marker names" do
    marker =
      ~s(<div class="mirror-macro" data-macro="blog-posts" data-spaces="ENG, OPS" ) <>
        ~s(data-labels="release" data-limit="3"></div>)

    expand(marker)

    assert asked() ==
             "space in (ENG, OPS) and label in (release) and type = blogpost " <>
               "order by created desc limit 3"
  end

  test "says so when the space has posted nothing" do
    StubContent.script(search: {:ok, []})

    assert text(expand()) == "This space has no blog posts yet."
  end

  test "a macro that names particular posts is not silently answered with others" do
    StubContent.script(search: {:ok, [page(2, "Release 2.0")]})

    html =
      expand(
        ~s(<div class="mirror-macro" data-macro="blog-posts" data-content="Release 2.0"></div>)
      )

    assert text(html) =~ "names particular posts"
    assert StubContent.questions() == []
  end

  defp asked do
    assert [{:search, cql}] = StubContent.questions()
    cql
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp titles(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("ul.mirror-dynamic-list a")
    |> Enum.map(&Floki.text/1)
  end

  defp page(id, title) do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: Page.slugify(title),
      type: "blogpost",
      space: @space,
      external_updated_at: ~U[2026-10-01 09:00:00Z]
    }
  end
end
