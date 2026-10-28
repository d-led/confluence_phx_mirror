defmodule ConfluencePhxMirror.Sync.DynamicContent.MarkerTest do
  @moduledoc """
  What a page's storage format says about its macros, turned into markers.

  The names and parameters are Confluence's, so these specs are as much a
  cross-check of ours against theirs as they are tests: `ac:name` decides which
  renderer runs, and a parameter keeps its name unless the mirror has a clearer
  word for it.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.Marker
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @page %{
    id: 1,
    confluence_id: 1001,
    slug: "page-1001",
    title: "Getting Started",
    space: %{key: "ENG"}
  }

  test "a macro the mirror draws becomes a marker carrying its parameters" do
    assert {:ok, node} = Marker.build("toc", [{"minLevel", "2"}, {"maxLevel", "3"}])

    assert node ==
             {"div",
              [
                {"class", "mirror-macro"},
                {"data-macro", "toc"},
                {"data-min-level", "2"},
                {"data-max-level", "3"}
              ], []}
  end

  test "the Page Properties Report is `detailssummary`, and its headings are columns" do
    assert {:ok, {"div", attributes, []}} =
             Marker.build("detailssummary", [{"headings", "Owner,Status"}])

    assert attribute(attributes, "data-macro") == "detailssummary"
    assert attribute(attributes, "data-columns") == "Owner,Status"
  end

  test "a result cap reads as a limit, whatever Confluence called it" do
    assert {:ok, {"div", capped, []}} =
             Marker.build("content-by-label", [{"labels", "runbook"}, {"maxResults", "5"}])

    assert attribute(capped, "data-limit") == "5"

    assert {:ok, {"div", sized, []}} = Marker.build("detailssummary", [{"pageSize", "20"}])
    assert attribute(sized, "data-limit") == "20"

    assert {:ok, {"div", capped_at, []}} = Marker.build("recently-updated", [{"max", "5"}])
    assert attribute(capped_at, "data-limit") == "5"
  end

  test "a report's query is carried as the page wrote it" do
    assert {:ok, {"div", attributes, []}} =
             Marker.build("content-report-table", [{"cql", "label = runbook limit 5"}])

    assert attribute(attributes, "data-cql") == "label = runbook limit 5"
  end

  test "the friendly name resolves to the macro Confluence stores" do
    assert {:ok, {"div", attributes, []}} = Marker.build("page-properties-report", [])

    assert attribute(attributes, "data-macro") == "detailssummary"
  end

  test "a macro the mirror cannot draw is left to the caller to explain" do
    assert Marker.build("jira", []) == :error
    assert Marker.build("blog-posts", []) == :error
    assert Marker.drawable?("children")
  end

  test "a parameter name keeps its case when it is turned into an attribute" do
    assert {:ok, {"div", attributes, []}} = Marker.build("children", [{"sort", "creation"}])

    assert attribute(attributes, "data-sort") == "creation"
  end

  test "the page an include names is carried as the page it named" do
    assert {:ok, {"div", attributes, []}} =
             Marker.build("include", [{"Page", "Architecture Overview"}])

    assert attribute(attributes, "data-page") == "Architecture Overview"
  end

  defp attribute(attributes, name), do: attributes |> List.keyfind(name, 0) |> elem(1)

  test "a stored macro renders through the expander once it is a marker" do
    StubContent.script(children: [])
    assert {:ok, marker} = Marker.build("children", [])

    html =
      DynamicContent.expand(Floki.raw_html([marker]), %{
        space: @page.space,
        page: @page,
        source: StubContent
      })

    assert html =~ "This page has no child pages."
  end
end
