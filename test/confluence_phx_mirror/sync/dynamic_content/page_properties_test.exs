defmodule ConfluencePhxMirror.Sync.DynamicContent.PagePropertiesTest do
  @moduledoc """
  *Page properties* is the table a page declares for its own reports, and the
  one thing that can be drawn from is the page itself.

  Three claims are pinned: the pairs come from the port and are drawn as the
  table the macro is, a page declaring none says so rather than showing an empty
  table, and the macro asks about its own page — not about the space, which is
  what the report does.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="pageproperties"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Architecture", space: @space}

  test "the properties the page declares are drawn, a property to a line" do
    StubContent.script(
      page_properties: [%{key: "Owner", value: "Platform"}, %{key: "Status", value: "Active"}]
    )

    assert properties(expand()) == [{"Owner", "Platform"}, {"Status", "Active"}]
  end

  test "it asks about this page's own properties" do
    expand()

    assert StubContent.questions() == [{:page_properties, 1001}]
  end

  test "a page that declares nothing says so instead of drawing an empty table" do
    html = expand()

    assert text(html) == "This page declares no properties."
    refute html =~ "<table"
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp properties(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("table.mirror-page-properties tr")
    |> Enum.map(fn row ->
      {"th", _, key} = Floki.find(row, "th") |> hd()
      {"td", _, value} = Floki.find(row, "td") |> hd()
      {Floki.text(key), Floki.text(value)}
    end)
  end
end
