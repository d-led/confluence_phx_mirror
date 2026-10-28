defmodule ConfluencePhxMirror.Sync.DynamicContent.RecentlyUpdatedTest do
  @moduledoc """
  *Recently Updated* asks the mirror a question, and the question is the test.

  What the macro shows is the port's answer; what matters is what it asked — the
  spaces and labels the marker named, the order, the limit — because that is the
  CQL a person would have had to write by hand.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="recently-updated"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    StubContent.script(search: {:ok, [page(2, "Deploys"), page(3, "Week 42 notes", "blogpost")]})
  end

  test "lists what the port answers, newest first" do
    assert titles(expand()) == ["Deploys", "Week 42 notes"]
  end

  test "links a post the way the mirror routes posts" do
    assert hrefs(expand()) == [
             "/spaces/ENG/pages/2/Deploys",
             "/spaces/ENG/blog/3/Week+42+notes"
           ]
  end

  test "asks for the newest pages and posts, ten of them" do
    expand()

    assert asked() == "type in (page, blogpost) order by lastmodified desc limit 10"
  end

  test "narrows to the spaces and labels the marker names" do
    expand(~s(<div class="mirror-macro" data-macro="recently-updated" data-spaces="ENG, OPS"
                data-labels="needs review" data-limit="5"></div>))

    assert asked() ==
             "space in (ENG, OPS) and label in (\"needs review\") and " <>
               "type in (page, blogpost) order by lastmodified desc limit 5"
  end

  test "a query the mirror refuses is shown as the reason" do
    StubContent.script(
      search: {:error, "the mirror cannot answer watcher: watching is per person"}
    )

    assert text(expand()) =~ "cannot be answered: the mirror cannot answer watcher"
  end

  test "says so when nothing has changed yet" do
    StubContent.script(search: {:ok, []})

    assert text(expand()) == "Nothing has been updated yet."
  end

  defp asked do
    assert [{:search, cql}] = StubContent.questions()
    cql
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp titles(html), do: html |> links() |> Enum.map(&Floki.text/1)
  defp hrefs(html), do: html |> links() |> Enum.map(&href/1)

  defp href(link), do: link |> Floki.attribute("href") |> List.first()

  defp links(html),
    do: html |> Floki.parse_fragment!() |> Floki.find("ul.mirror-dynamic-list a")

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp page(id, title, type \\ "page") do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: Page.slugify(title),
      type: type,
      space: @space,
      external_updated_at: ~U[2026-10-01 09:00:00Z]
    }
  end
end
