defmodule ConfluencePhxMirror.Sync.DynamicContent.PagePropertiesReportTest do
  @moduledoc """
  *Page Properties Report* resolved from the properties a sync stored.

  A space has one row per page that declares properties, so a report without a
  cap is the whole catalogue. What the macro asks the port for is therefore the
  interesting part: one window of rows, as wide as the marker allows.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Product Hub", space: @space}
  @marker ~s(<div class="mirror-macro" data-macro="detailssummary" data-columns="Owner"></div>)

  setup do
    StubContent.script(property_report: %{columns: ["Owner"], rows: []})
  end

  test "asks for fifty rows unless the marker says otherwise" do
    expand(@marker)

    assert StubContent.questions() == [{:property_report, nil, [limit: 50]}]
  end

  test "asks for as many rows as the marker allows" do
    expand(~s(<div class="mirror-macro" data-macro="detailssummary" data-limit="5"></div>))

    assert StubContent.questions() == [{:property_report, nil, [limit: 5]}]
  end

  test "says so when no page declares properties" do
    assert expand(@marker) =~ "No page in this space declares properties yet."
  end

  defp expand(marker) do
    DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})
  end
end
