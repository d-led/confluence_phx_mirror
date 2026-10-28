defmodule ConfluencePhxMirror.Sync.DynamicContent.ContentReportTableTest do
  @moduledoc """
  *Content Report Table* is a page asking the mirror a CQL question.

  Two things are worth pinning: the query the page wrote reaches the port
  unchanged (it is the page author's query, not the mirror's rewrite), and a
  query the mirror refuses is shown as a reason rather than as an empty table.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Runbooks", space: @space}
  @cql "label = runbook order by lastmodified desc limit 5"
  @marker ~s(<div class="mirror-macro" data-macro="content-report-table" data-cql="#{@cql}"></div>)

  setup do
    StubContent.script(search: {:ok, [page(2, "Deploys", "OPS"), page(3, "Rollbacks", "ENG")]})
  end

  test "asks the port the query the page wrote" do
    expand()

    assert StubContent.questions() == [{:search, @cql}]
  end

  test "one row per match, with the space and the day it changed" do
    document = Floki.parse_fragment!(expand())
    headers = document |> Floki.find("thead th") |> Enum.map(&Floki.text/1)
    rows = document |> Floki.find("tbody tr") |> Enum.map(&row/1)

    assert headers == ["Title", "Space", "Last modified"]

    assert rows == [
             ["Deploys", "OPS", "01 Oct 2026"],
             ["Rollbacks", "ENG", "01 Oct 2026"]
           ]
  end

  test "each title opens the page inside the mirror" do
    assert Floki.find(Floki.parse_fragment!(expand()), "tbody td a") |> Enum.map(&href/1) == [
             "/spaces/OPS/pages/2/Deploys",
             "/spaces/ENG/pages/3/Rollbacks"
           ]
  end

  test "a query the mirror refuses shows the reason, not an empty table" do
    StubContent.script(search: {:error, "unknown field \"author\""})

    assert text(expand()) == ~s(This report's query cannot be answered: unknown field "author")
    assert Floki.find(Floki.parse_fragment!(expand()), "table") == []
  end

  test "no match says no match" do
    StubContent.script(search: {:ok, []})

    assert text(expand()) == "No content matches this report's query."
  end

  test "a report without a query says why it is empty" do
    marker = ~s(<div class="mirror-macro" data-macro="content-report-table"></div>)

    assert text(expand(marker)) == "This report names no CQL query, so it lists nothing."
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp row(tr), do: tr |> Floki.find("td") |> Enum.map(&Floki.text/1)
  defp href(link), do: link |> Floki.attribute("href") |> List.first()
  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp page(id, title, space_key) do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: Page.slugify(title),
      type: "page",
      space: %{key: space_key},
      external_updated_at: ~U[2026-10-01 09:00:00Z]
    }
  end
end
