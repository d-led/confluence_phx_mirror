defmodule ConfluencePhxMirror.Sync.DynamicContent.RoadmapTest do
  @moduledoc """
  *Roadmap planner* drawn from the document the editor stores inside the macro.

  The plan is one URL-encoded JSON parameter, so the timeline in the picture has
  to be the timeline in the document: the same months, the same lanes in the same
  order, and a bar as long as the days it says it lasts.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "MFS"}
  @host %{id: 1, confluence_id: 32_001, slug: "page-32_001", title: "Plan", space: @space}

  # The link the editor wrote when a bar was pointed at "Architecture Overview",
  # word for word.
  @page_link %{
    "id" => "884738",
    "title" => "Architecture Overview",
    "type" => "page",
    "wikiLink" => "[MFS:Architecture Overview]",
    "spaceKey" => "MFS"
  }

  # What the editor wrote on "Macro capture 2026-11-06", word for word.
  defp captured do
    %{
      "title" => "Roadmap Planner",
      "timeline" => %{
        "startDate" => "2026-11-06 00:00:00",
        "endDate" => "2027-10-06 00:00:00",
        "displayOption" => "MONTH"
      },
      "lanes" => [
        %{
          "title" => "Lane 1",
          "color" => %{"lane" => "#f6c342", "bar" => "#f6c342", "text" => "#594300", "count" => 1},
          "bars" => [
            bar("Bar 1", "This is the first bar.", "2026-11-01 00:00:00", 2, 0)
            |> linked_to(@page_link),
            bar("Bar 2", "This is the second bar.", "2026-11-01 00:00:00", 1, 1)
          ]
        },
        %{
          "title" => "Lane 2",
          "color" => %{"lane" => "#3b7fc4", "bar" => "#3b7fc4", "text" => "#ffffff", "count" => 1},
          "bars" => [bar("Bar 3", "This is the third bar.", "2026-11-01 00:00:00", 2.5, 0)]
        }
      ],
      "markers" => [%{"title" => "Marker 1", "markerDate" => "2026-11-15 00:00:00"}]
    }
  end

  test "the months the plan spans are the columns across the top" do
    assert columns(expand(captured())) == ~w(Nov Dec Jan Feb Mar Apr May Jun Jul Aug Sep Oct)
  end

  test "each lane is a row, in the order the plan lists them" do
    assert lane_titles(expand(captured())) == ["Lane 1", "Lane 2"]
  end

  test "a lane holds the bars the plan puts in it" do
    assert titles(expand(captured())) == ["Bar 1", "Bar 2", "Bar 3"]
  end

  # Two bars that begin on the same day would paint over each other; the plan
  # gives each a row of its own, and the lane is as tall as its rows.
  test "bars that start together sit on their own rows" do
    html = expand(captured())

    assert row(html, "Bar 1") == 0
    assert row(html, "Bar 2") == 1
    assert track_rows(html) == [2, 1]
  end

  # Two months is twice one month, and two and a half months is drawn as two and
  # a half rather than rounded to a whole column.
  test "a longer bar is a wider bar" do
    html = expand(captured())

    assert_in_delta width(html, "Bar 1"), 2 * width(html, "Bar 2"), 0.01
    assert_in_delta width(html, "Bar 3"), 2.5 * width(html, "Bar 2"), 0.01
  end

  test "a bar starts where its start date puts it, not at the left edge" do
    html =
      expand(%{
        captured()
        | "lanes" => [lane("Lane 1", [bar("Bar 4", "", "2027-01-01 00:00:00", 1, 0)])]
      })

    # January is the third column of a timeline that opens in November.
    assert_in_delta left(html, "Bar 4"), 2 * width(html, "Bar 4"), 0.01
  end

  test "a marker is a rule at its day, not at the edge of its month" do
    html = expand(captured())
    month = width(html, "Bar 2")

    # 15 November is halfway through the first column, not on its line.
    assert_in_delta left(html, "Marker 1"), month / 2, month * 0.05
  end

  test "a bar keeps the words its author gave it" do
    assert detail(expand(captured()), "Bar 1") == "This is the first bar."
  end

  test "the plan's own title is what the block is headed with" do
    assert heading(expand(captured())) == "Roadmap Planner"
  end

  test "the range the timeline covers is said in words" do
    assert expand(captured()) =~ "Nov 2026 – Oct 2027"
  end

  test "a macro that carries no roadmap says so instead of drawing an empty chart" do
    html = expand(nil)

    assert text(html) =~ "carries no roadmap"
    assert titles(html) == []
  end

  test "a plan that is not a document the mirror can read says so" do
    html =
      expand(~s(<div class="mirror-macro" data-macro="roadmap" data-source="not%20json"></div>))

    assert text(html) =~ "cannot be read"
    assert titles(html) == []
  end

  test "a plan with no bars says it has nothing planned" do
    html = expand(%{captured() | "lanes" => [lane("Lane 1", [])]})

    assert text(html) =~ "nothing planned"
  end

  describe "a bar that names a page" do
    test "is a link to that page in the mirror" do
      StubContent.script(page_by_title: fn "Architecture Overview" -> {:ok, target()} end)

      assert {"a", attributes, ["Bar 1"]} = bar_node(expand(captured()), "Bar 1")

      assert Map.new(attributes)["href"] ==
               "/spaces/MFS/pages/884738/Architecture+Overview"
    end

    # The page is asked of the content port, which is where the audience rule
    # lives: a bar whose page these readers may not open is a bar, not an address
    # and not a trip to the site.
    test "is a plain bar when the mirror cannot answer for that page" do
      assert {"span", _attributes, ["Bar 1"]} = bar_node(expand(captured()), "Bar 1")
    end

    test "asks for a page in another space by the name Confluence writes" do
      StubContent.script(page_by_title: fn _title -> {:ok, target()} end)

      elsewhere = %{@page_link | "spaceKey" => "OPS"}

      plan =
        update_in(captured()["lanes"], fn [lane | rest] -> [relinked(lane, elsewhere) | rest] end)

      expand(plan)

      assert {:page_by_title, "OPS/Architecture Overview"} in StubContent.questions()
    end
  end

  defp bar_node(html, title) do
    html
    |> nodes(".mirror-roadmap-bar")
    |> Enum.find(&(Floki.text(&1) == title))
  end

  defp target do
    %ConfluencePhxMirror.Mirror.Page{
      confluence_id: 884_738,
      slug: "Architecture+Overview",
      title: "Architecture Overview",
      space: @space
    }
  end

  defp linked_to(bar, page_link), do: %{bar | "pageLink" => page_link}

  defp relinked(lane, page_link) do
    %{lane | "bars" => Enum.map(lane["bars"], &linked_to(&1, page_link))}
  end

  defp expand(marker) when is_binary(marker), do: DynamicContent.expand(marker, context())

  defp expand(nil),
    do: expand(~s(<div class="mirror-macro" data-macro="roadmap"></div>))

  defp expand(document), do: document |> Jason.encode!() |> URI.encode() |> marker() |> expand()

  defp marker(json),
    do: ~s(<div class="mirror-macro" data-macro="roadmap" data-source="#{json}"></div>)

  defp context, do: %{space: @space, page: @host, source: StubContent}

  defp bar(title, description, start, duration, row) do
    %{
      "title" => title,
      "description" => description,
      "startDate" => start,
      "duration" => duration,
      "rowIndex" => row,
      "id" => "#{title}-id",
      "pageLink" => %{}
    }
  end

  defp lane(title, bars), do: %{"title" => title, "color" => %{}, "bars" => bars}

  defp columns(html) do
    html
    |> nodes(".mirror-roadmap-month")
    |> Enum.map(&Floki.text/1)
  end

  defp lane_titles(html) do
    html
    |> nodes(".mirror-roadmap-lane-title")
    |> Enum.map(&Floki.text/1)
  end

  defp titles(html), do: html |> nodes(".mirror-roadmap-bar") |> Enum.map(&Floki.text/1)

  defp heading(html), do: html |> nodes(".mirror-dynamic-heading") |> Enum.map_join(&Floki.text/1)

  defp text(html), do: html |> document() |> Floki.text()

  defp row(html, title), do: html |> placed(".mirror-roadmap-bar", title) |> Map.fetch!("--row")

  defp track_rows(html) do
    html
    |> nodes(".mirror-roadmap-track")
    |> Enum.map(fn track -> track |> style() |> Map.fetch!("--rows") end)
  end

  defp width(html, title), do: html |> placed(".mirror-roadmap-bar", title) |> Map.fetch!("width")

  defp left(html, title),
    do: html |> placed(".mirror-roadmap-bar, .mirror-roadmap-marker", title) |> Map.fetch!("left")

  defp detail(html, title) do
    html
    |> document()
    |> Floki.find(".mirror-roadmap-bar")
    |> Enum.find(&(Floki.text(&1) == title))
    |> Floki.attribute("title")
    |> List.first()
  end

  defp placed(html, selector, title) do
    html
    |> document()
    |> Floki.find(selector)
    |> Enum.find(&(Floki.text(&1) == title))
    |> style()
  end

  defp style(nil), do: %{}

  defp style(node) do
    node
    |> Floki.attribute("style")
    |> List.first()
    |> to_string()
    |> String.split(";", trim: true)
    |> Map.new(fn declaration ->
      [name, value] = String.split(declaration, ":", parts: 2)
      {String.trim(name), number(String.trim(value))}
    end)
  end

  defp number(value) do
    case Float.parse(String.trim_trailing(value, "%")) do
      {number, ""} -> number
      _words -> value
    end
  end

  defp nodes(html, selector), do: html |> document() |> Floki.find(selector)
  defp document(html), do: Floki.parse_fragment!(html)
end
