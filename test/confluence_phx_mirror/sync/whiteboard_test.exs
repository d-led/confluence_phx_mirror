defmodule ConfluencePhxMirror.Sync.WhiteboardTest do
  @moduledoc """
  A whiteboard drawn from its document.

  The document is what GraphQL returns as `WHITEBOARD_DOC_FORMAT`: a node per
  shape with a position, a size, a z-index and an ADF document for its words.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.Whiteboard

  test "draws a box and its words for each shape, in z-order" do
    assert {:ok, svg} = Whiteboard.svg(document([{"January", 10}, {"February", 300}]))
    assert svg =~ ~r{<svg class="mirror-whiteboard" viewBox="}
    assert length(String.split(svg, "<rect")) - 1 == 2
    assert svg =~ "January"
    assert svg =~ "February"
    assert svg =~ ~s(fill="#deebff")
  end

  test "keeps the drawing inside the frame it declares" do
    assert {:ok, svg} = Whiteboard.svg(document([{"January", 10}, {"February", 300}]))
    # x 10..500 and y 20..100, plus the margin on every side.
    assert svg =~ ~r/viewBox="-30 -20 570 160"/
  end

  test "a document version this mirror does not know is not drawn" do
    assert Whiteboard.svg(%{"version" => "2030-01-01_ALPHA", "nodes" => %{"a" => shape(0, "x")}}) ==
             :error
  end

  test "a board with nothing in it is not drawn" do
    assert Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => %{}}) == :error

    nodes = %{"a" => %{"id" => "a", "type" => "frame"}}
    assert Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => nodes}) == :error
  end

  test "a shape without geometry is skipped, not guessed at" do
    nodes = %{
      "a" => shape(0, "January"),
      "b" => %{"id" => "b", "type" => "shape", "text" => nil}
    }

    assert {:ok, svg} = Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => nodes})
    assert length(String.split(svg, "<rect")) - 1 == 1
  end

  defp document(shapes) do
    %{
      "version" => "2024-05-20_ALPHA",
      "nodes" =>
        shapes
        |> Enum.with_index()
        |> Map.new(fn {{word, x}, index} -> {"n#{index}", shape(x, word)} end),
      "edges" => %{}
    }
  end

  defp shape(x, word) do
    %{
      "id" => "n-#{word}",
      "type" => "shape",
      "zIndex" => String.length(word),
      "color" => "light-blue",
      "geometry" => %{
        "position" => %{"x" => x, "y" => 20},
        "size" => %{"x" => 200, "y" => 80}
      },
      "text" => words(word)
    }
  end

  defp words(word) do
    JSON.encode!(%{
      "type" => "doc",
      "content" => [
        %{"type" => "heading", "content" => [%{"type" => "text", "text" => word}]}
      ]
    })
  end
end
