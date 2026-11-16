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

  test "a board's dotted palette name is drawn in the colour it names" do
    nodes = %{"a" => %{shape(0, "January") | "color" => "palette.light.blue.200"}}

    assert {:ok, svg} = Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => nodes})
    assert svg =~ ~s(fill="#deebff")
  end

  test "a colour this mirror does not know is drawn neutrally" do
    nodes = %{"a" => %{shape(0, "January") | "color" => "palette.dark.taupe.700"}}

    assert {:ok, svg} = Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => nodes})
    assert svg =~ ~s(fill="#ffffff")
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

  test "knows the document version it draws, and says so about no other" do
    assert Whiteboard.known_version?(%{"version" => "2024-05-20_ALPHA"})
    refute Whiteboard.known_version?(%{"version" => "2030-01-01_ALPHA"})
    refute Whiteboard.known_version?(%{"nodes" => %{}})
  end

  # A board may store a coordinate as the text it was typed as, a unit suffix and
  # all: the drawing reads the number it starts with and ignores the rest.
  test "a coordinate written as text is read as the number it starts with" do
    nodes = %{"a" => shape(0, "January") |> put_in(["geometry", "position", "x"], "10px")}

    assert {:ok, svg} = Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => nodes})
    assert svg =~ ~s(<rect x="10")
  end

  # Nothing to read is a coordinate of zero, and a shape with no width is drawn as
  # a sliver rather than disappearing: a board is worth seeing even when its
  # numbers are unreadable.
  test "a coordinate that is not a number is drawn at zero" do
    nodes =
      %{"a" => shape(0, "January")}
      |> put_in(["a", "geometry", "size", "x"], "wide")

    assert {:ok, svg} = Whiteboard.svg(%{"version" => "2024-05-20_ALPHA", "nodes" => nodes})
    assert svg =~ ~s(width="1")
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
