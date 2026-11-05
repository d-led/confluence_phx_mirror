defmodule ConfluencePhxMirror.Sync.DynamicContent.NativeEmbedTest do
  @moduledoc """
  *Whiteboards and Databases*: a board is drawn from its document, and anything
  the mirror cannot read is answered with an apology and a link.

  Confluence's export view carries an unknown-macro placeholder for both, so the
  document (whiteboard) or the address (database) is all there is to go on.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "MFS"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Macros Gallery", space: @space}
  @board "https://dled.atlassian.net/wiki/spaces/MFS/whiteboard/28344336"

  test "a whiteboard is drawn from its document" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ ~s(class="mirror-whiteboard")
    assert html =~ ~s(href="#{@board}")
    assert drawn_words(html) =~ "January"
  end

  test "the link under a drawing is a caption, not the address itself" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "<figcaption"
    assert html =~ ~s(href="#{@board}")
    assert html =~ "Whiteboard in Confluence"
    refute html =~ ">#{@board}<"
  end

  test "the drawing opens over the page as a control, and a saved copy knows its board" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "data-whiteboard-zoom"
    assert html =~ ~s(data-whiteboard-name="whiteboard-28344336.svg")
    assert html =~ ~s(aria-label="Open the whiteboard full screen")
  end

  test "a board the mirror cannot read apologises and points at the original" do
    StubContent.script(whiteboard: {:error, :not_found})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "could not draw this whiteboard"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "data:image/svg+xml"
  end

  test "a document version this mirror does not know apologises too" do
    StubContent.script(whiteboard: {:ok, %{document("January") | "version" => "2030-01-01"}})

    assert expand(marker("native-embed:whiteboard", @board)) =~ "could not draw this whiteboard"
  end

  test "a database is named and linked, since a view cannot be a still" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:database", @board))

    assert html =~ "Database"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "data:image/svg+xml"
  end

  test "an embed with no address says why it cannot be linked" do
    StubContent.script(whiteboard: {:ok, document("January")})

    assert expand(marker("native-embed:whiteboard", nil)) =~
             "the embed names no address, so the mirror cannot link to it"
  end

  defp document(word) do
    %{
      "version" => "2024-05-20_ALPHA",
      "nodes" => %{
        "a" => %{
          "id" => "a",
          "type" => "shape",
          "zIndex" => 1,
          "geometry" => %{
            "position" => %{"x" => 10, "y" => 20},
            "size" => %{"x" => 200, "y" => 80}
          },
          "text" =>
            JSON.encode!(%{
              "type" => "doc",
              "content" => [%{"type" => "text", "text" => word}]
            })
        }
      },
      "edges" => %{}
    }
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

  # The drawing travels as a data URI, so its words are only visible once the
  # picture is decoded — which is what a reader's browser does.
  defp drawn_words(html) do
    with [_, base64] <- Regex.run(~r{data:image/svg\+xml;base64,([^"]+)}, html),
         {:ok, svg} <- Base.decode64(base64) do
      svg
    else
      _nothing_drawn -> ""
    end
  end
end
