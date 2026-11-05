defmodule ConfluencePhxMirror.Sync.DynamicContent.NativeEmbedTest do
  @moduledoc """
  *Whiteboards and Databases* say where they are, because drawing them is not
  something a mirror can do.

  Confluence's export view carries an unknown-macro placeholder for both, so the
  only useful answer is the address the page recorded.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "MFS"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Macros Gallery", space: @space}
  @board "https://dled.atlassian.net/wiki/spaces/MFS/whiteboard/28344336"

  setup do
    StubContent.script([])
  end

  test "a whiteboard is named and linked, not drawn" do
    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "Whiteboard"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "unknown"
  end

  test "a database is named too" do
    assert expand(marker("native-embed:database", @board)) =~ "Database"
  end

  test "an embed with no address says why it cannot be linked" do
    assert expand(marker("native-embed:whiteboard", nil)) =~
             "the embed names no address, so the mirror cannot link to it"
  end

  defp marker(name, url) do
    attributes =
      case url do
        nil -> ~s(data-macro="#{name}")
        url -> ~s(data-macro="#{name}" data-url="#{url}")
      end

    ~s(<div class="mirror-macro" #{attributes}></div>)
  end

  defp expand(marker) do
    DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})
  end
end
