defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Roadmap do
  @moduledoc """
  *Roadmap planner*: a plan somebody drew on a timeline, drawn here as a timeline.

  Confluence stores the whole plan inside the macro, as one URL-encoded JSON
  parameter:

      <ac:parameter ac:name="source">%7B%22title%22%3A%22Roadmap%20Planner%22…</ac:parameter>

      { "title": "Roadmap Planner",
        "timeline": {"startDate": "2026-11-06 00:00:00",
                     "endDate": "2027-10-06 00:00:00",
                     "displayOption": "MONTH"},
        "lanes": [{"title": "Lane 1", "color": {"lane": "…", "bar": "…", "text": "…"},
                   "bars": [{"title": "Bar 1", "description": "…",
                             "startDate": "2026-11-01 00:00:00", "duration": 2,
                             "rowIndex": 0, "id": "…", "pageLink": {}}]}],
        "markers": [{"title": "Marker 1", "markerDate": "2026-11-15 00:00:00"}] }

  So nothing outside the page is needed to draw it — no network, no Jira: the
  columns are the timeline's own units, one row per lane, and a bar is as wide as
  its `duration`. A `duration` counts the timeline's unit, which is what the
  site's own picture shows: under `MONTH`, a bar of 2 runs from 1 November to 1
  January, and one of 2.5 stops midway through January.

  A bar may also name a page. The editor writes that as the key and title of the
  page, in the plan and beside it:

      "pageLink": {"id": "884738", "title": "Architecture Overview",
                   "type": "page", "wikiLink": "[MFS:Architecture Overview]",
                   "spaceKey": "MFS"}

  The page is looked up through the content port, so the bar is a link only when
  the mirror holds that page and this page's readers may open it — the same rule
  every other macro that names a page obeys. A bar whose page the mirror cannot
  answer for stays a bar: the reader is not sent to the site for it.

  One thing is deliberately not drawn: anything the plan does not carry. A macro
  with no document, one that is not JSON, and one the mirror cannot place a
  single bar on say so in words rather than drawing an empty grid, because an
  empty grid is what "no plan at all" and "a plan the mirror failed to read"
  look like.

  A plan too long for a page — more than 60 columns of its own unit — is
  refused for the same reason: the picture would be a smear nobody can read.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  # More columns than this is not a plan anyone reads at a glance, and the grid
  # is drawn from them one by one.
  @max_columns 60

  # A lane or a bar the document gives no usable colour for still has to be
  # drawn: neutral paint, not invisible paint.
  @default_lane "#94a3b8"
  @default_bar "#64748b"
  @default_text "#ffffff"

  @colours %{
    "DAY" => :day,
    "WEEK" => :week,
    "MONTH" => :month,
    "QUARTER" => :quarter,
    "QUARTERS" => :quarter,
    "YEAR" => :year
  }

  @hex_colour ~r/\A#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\z/

  @impl true
  def render(attrs, %Context{} = context) do
    case plan(attrs) do
      {:ok, plan} ->
        [Nodes.heading(plan.title), chart(linked(plan, context))]

      {:error, :empty} ->
        [Nodes.notice("Roadmap: this macro carries no roadmap.")]

      {:error, :unreadable} ->
        [Nodes.notice("Roadmap: the roadmap in this macro cannot be read.")]

      {:error, :nothing_planned} ->
        [Nodes.empty("This roadmap has nothing planned on it.")]

      {:error, :too_long} ->
        [Nodes.notice("Roadmap: this timeline is too long to draw here.")]
    end
  end

  # -- the plan ---------------------------------------------------------------

  defp plan(attrs) do
    with {:ok, document} <- decode(attrs),
         {:ok, axis} <- axis(document["timeline"]),
         {:ok, lanes} <- lanes(document["lanes"], axis) do
      {:ok,
       %{
         title: title(document, attrs),
         axis: axis,
         lanes: lanes,
         markers: markers(document["markers"], axis)
       }}
    end
  end

  defp decode(attrs) do
    case blank(Map.get(attrs, "source")) do
      nil ->
        {:error, :empty}

      source ->
        source |> URI.decode() |> Jason.decode() |> decoded()
    end
  end

  defp decoded({:ok, document}) when is_map(document), do: {:ok, document}
  defp decoded(_not_a_document), do: {:error, :unreadable}

  defp title(document, attrs) do
    [document["title"], attrs |> Map.get("title", "") |> URI.decode()]
    |> Enum.find_value("Roadmap", &blank/1)
  end

  # -- the axis ---------------------------------------------------------------

  defp axis(timeline) do
    kind = kind(timeline)

    with {:ok, {first, last}} <- span(timeline),
         {:ok, starts} <- unit_starts(first, last, kind) do
      {:ok, %{kind: kind, units: Enum.map(starts, &unit(kind, &1)), first: first, last: last}}
    end
  end

  defp kind(timeline) when is_map(timeline) do
    timeline
    |> Map.get("displayOption")
    |> to_string()
    |> String.upcase()
    |> then(&Map.get(@colours, &1, :month))
  end

  defp kind(_timeline), do: :month

  defp span(timeline) when is_map(timeline) do
    with {:ok, first} <- date(timeline["startDate"]),
         {:ok, last} <- date(timeline["endDate"]),
         true <- Date.compare(first, last) != :gt do
      {:ok, {first, last}}
    else
      _no_span -> {:error, :unreadable}
    end
  end

  defp span(_timeline), do: {:error, :unreadable}

  defp unit_starts(first, last, kind) do
    starts =
      first
      |> floor_to(kind)
      |> Stream.iterate(&next(&1, kind))
      |> Enum.take_while(&(Date.compare(&1, floor_to(last, kind)) != :gt))

    case length(starts) <= @max_columns do
      true -> {:ok, starts}
      false -> {:error, :too_long}
    end
  end

  defp unit(kind, start),
    do: %{start: start, finish: next(start, kind), label: label(kind, start)}

  defp floor_to(date, :day), do: date
  defp floor_to(date, :week), do: Date.add(date, 1 - Date.day_of_week(date))
  defp floor_to(date, :month), do: %{date | day: 1}
  defp floor_to(date, :quarter), do: %{date | day: 1, month: quarter_start(date.month)}
  defp floor_to(date, :year), do: %{date | day: 1, month: 1}

  defp quarter_start(month), do: 3 * div(month - 1, 3) + 1

  defp next(date, :day), do: Date.add(date, 1)
  defp next(date, :week), do: Date.add(date, 7)
  defp next(date, :month), do: shift(date, 1)
  defp next(date, :quarter), do: shift(date, 3)
  defp next(date, :year), do: shift(date, 12)

  defp shift(date, months) do
    total = date.year * 12 + date.month - 1 + months
    year = div(total, 12)
    month = rem(total, 12) + 1

    %{
      date
      | year: year,
        month: month,
        day: min(date.day, :calendar.last_day_of_the_month(year, month))
    }
  end

  defp label(:year, start), do: Integer.to_string(start.year)
  defp label(:quarter, start), do: "Q#{div(start.month - 1, 3) + 1}"
  defp label(:month, start), do: Calendar.strftime(start, "%b")
  defp label(_days, start), do: Calendar.strftime(start, "%d %b")

  # -- where a moment stands on the axis --------------------------------------

  defp position(axis, date) do
    case Enum.find_value(Enum.with_index(axis.units), &index_of(&1, date)) do
      nil -> edge(axis, date)
      index -> index + within(Enum.at(axis.units, index), date)
    end
  end

  defp index_of({unit, index}, date) do
    if Date.compare(date, unit.start) != :lt and Date.compare(date, unit.finish) == :lt,
      do: index
  end

  # A bar or a marker the plan puts outside its own timeline is drawn up to the
  # edge rather than off the picture.
  defp edge(axis, date) do
    case Date.compare(date, axis.first) do
      :lt -> 0.0
      _after -> length(axis.units) * 1.0
    end
  end

  defp within(%{start: start, finish: finish}, date) do
    days = Date.diff(finish, start)

    if days <= 0,
      do: 0.0,
      else: (Date.diff(date, start) / days) |> max(0.0) |> min(1.0)
  end

  defp percent(position, axis), do: Float.round(position / length(axis.units) * 100, 3)

  # -- lanes and bars ---------------------------------------------------------

  defp lanes(lanes, axis) do
    lanes = lanes |> List.wrap() |> Enum.filter(&is_map/1)

    case Enum.flat_map(lanes, &bars_in(&1, axis)) do
      [] -> {:error, :nothing_planned}
      _bars -> {:ok, Enum.map(lanes, &lane(&1, axis))}
    end
  end

  defp lane(lane, axis) do
    bars = bars_in(lane, axis)
    rows = Enum.max(Enum.map(bars, & &1.row), fn -> 0 end) + 1

    %{
      title: blank(lane["title"]) || "Untitled lane",
      colour: paint(lane["color"], "lane", @default_lane),
      bars: bars,
      rows: rows
    }
  end

  defp bars_in(lane, axis) do
    lane |> Map.get("bars") |> List.wrap() |> Enum.flat_map(&bar(&1, lane, axis))
  end

  # A bar the document gives no readable start or length cannot be placed; it is
  # left out rather than drawn where it probably is not.
  defp bar(%{"title" => title} = bar, lane, axis) when is_binary(title) do
    with {:ok, start} <- date(bar["startDate"]),
         {:ok, duration} <- duration(bar["duration"]) do
      [placed(bar, lane, axis, start, duration)]
    else
      _unplaceable -> []
    end
  end

  defp bar(_bar, _lane, _axis), do: []

  # The bar is as wide as the duration the document gives it, measured in the
  # timeline's own columns — which is what the site's own picture draws (two
  # months is two columns, two and a half is two and a half). A bar that runs off
  # the end of the timeline stops at its edge instead of painting past it.
  defp placed(bar, lane, axis, start, duration) do
    columns = length(axis.units)
    left = min(position(axis, start), columns * 1.0)
    width = duration |> min(columns - left) |> max(0.0)

    %{
      title: String.trim(bar["title"]),
      description: blank(bar["description"]),
      row: row(bar["rowIndex"]),
      page_link: bar["pageLink"],
      bar: paint(lane["color"], "bar", @default_bar),
      text: paint(lane["color"], "text", @default_text),
      left: percent(left, axis),
      width: percent(width, axis)
    }
  end

  # Two bars may start on the same day; the plan gives each the row it is drawn
  # on, and a bar two steps down a lane with nothing beside it keeps its place.
  defp row(value) when is_integer(value) and value >= 0, do: value
  defp row(_value), do: 0

  defp duration(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
  defp duration(_value), do: :error

  # -- markers ----------------------------------------------------------------

  defp markers(markers, axis) do
    markers |> List.wrap() |> Enum.flat_map(&marker(&1, axis))
  end

  defp marker(%{"markerDate" => value} = marker, axis) do
    with title when is_binary(title) and title != "" <- blank(marker["title"]),
         {:ok, at} <- date(value) do
      [%{title: title, left: percent(position(axis, at), axis)}]
    else
      _unplaceable -> []
    end
  end

  defp marker(_marker, _axis), do: []

  # -- the pages the plan names ----------------------------------------------

  # A bar that names a page is a link to it here, and an answer the mirror does
  # not have leaves the bar as it was. The lookup is the content port's, so the
  # audience rule is asked once, in the one place that owns it.
  defp linked(plan, %Context{} = context) do
    lanes =
      Enum.map(plan.lanes, fn lane ->
        %{lane | bars: Enum.map(lane.bars, &Map.put(&1, :href, href(&1.page_link, context)))}
      end)

    %{plan | lanes: lanes}
  end

  defp href(%{"title" => title} = link, context) when is_binary(title) and title != "" do
    case context.source.page_by_title(context.page, reference(title, link["spaceKey"], context)) do
      {:ok, page} -> URLs.content_path(page.space.key, page)
      :error -> nil
    end
  end

  defp href(_link, _context), do: nil

  # A bar in another space is written the way Confluence writes one —
  # `KEY/Page Title` — because that is the spelling the content port reads.
  defp reference(title, space_key, context) do
    cond do
      not is_binary(space_key) or space_key == "" -> title
      space_key == key(context.space) -> title
      true -> "#{space_key}/#{title}"
    end
  end

  defp key(%{key: key}), do: key
  defp key(_space), do: nil

  # -- the picture ------------------------------------------------------------

  defp chart(plan) do
    {"figure", [{"class", "mirror-roadmap"}],
     [
       {"figcaption", [{"class", "mirror-roadmap-range"}], [range(plan)]},
       {"div",
        [{"class", "mirror-roadmap-grid"}, {"style", "--columns: #{length(plan.axis.units)}"}],
        rows(plan)}
     ]}
  end

  defp range(plan) do
    Calendar.strftime(plan.axis.first, "%b %Y") <>
      " – " <> Calendar.strftime(plan.axis.last, "%b %Y")
  end

  # One grid, two columns: the lane's name and the timeline beside it. Every row
  # puts exactly one cell in each, so the tracks all start at the same place and
  # a month's column is a column on every row.
  defp rows(plan) do
    header(plan) ++ Enum.flat_map(plan.lanes, &lane_row/1) ++ marker_row(plan)
  end

  defp header(plan) do
    [
      {"p", [{"class", "mirror-roadmap-corner"}, {"aria-hidden", "true"}], []},
      {"p", [{"class", "mirror-roadmap-months"}, {"aria-hidden", "true"}],
       Enum.map(plan.axis.units, &month/1)}
    ]
  end

  defp month(unit), do: {"span", [{"class", "mirror-roadmap-month"}], [unit.label]}

  defp lane_row(lane) do
    [
      {"p", [{"class", "mirror-roadmap-lane-title"}, {"style", "--lane: #{lane.colour}"}],
       [lane.title]},
      {"div", [{"class", "mirror-roadmap-track"}, {"style", "--rows: #{lane.rows}"}],
       Enum.map(lane.bars, &bar_node/1)}
    ]
  end

  defp bar_node(bar) do
    {tag, ref} = if bar.href, do: {"a", [{"href", bar.href}]}, else: {"span", []}

    {tag,
     ref ++
       [
         {"class", "mirror-roadmap-bar"},
         {"style",
          "left:#{bar.left}%;width:#{bar.width}%;--row:#{bar.row};" <>
            "background:#{bar.bar};color:#{bar.text}"},
         {"title", bar.description || bar.title}
       ], [bar.title]}
  end

  defp marker_row(%{markers: []}), do: []

  defp marker_row(plan) do
    [
      {"p", [{"class", "mirror-roadmap-corner"}, {"aria-hidden", "true"}], []},
      {"div", [{"class", "mirror-roadmap-marker-row"}], Enum.map(plan.markers, &marker_node/1)}
    ]
  end

  defp marker_node(marker) do
    {"span", [{"class", "mirror-roadmap-marker"}, {"style", "left:#{marker.left}%"}],
     [{"span", [{"class", "mirror-roadmap-marker-label"}], [marker.title]}]}
  end

  # -- reading the document ---------------------------------------------------

  # The editor writes `2026-11-06 00:00:00`; a hand-written one may be a date.
  defp date(value) when is_binary(value) do
    text = String.replace(value, " ", "T", global: false)

    case NaiveDateTime.from_iso8601(text) do
      {:ok, moment} -> {:ok, NaiveDateTime.to_date(moment)}
      {:error, _date_only} -> Date.from_iso8601(text)
    end
  end

  defp date(_value), do: :error

  # A colour comes from the page, so it is checked before it reaches a style: a
  # value that is not a hex colour is not a colour.
  defp paint(%{} = colours, key, fallback) do
    value = colours[key]

    if is_binary(value) and Regex.match?(@hex_colour, value), do: value, else: fallback
  end

  defp paint(_colours, _key, fallback), do: fallback

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank(_value), do: nil
end
