defmodule ConfluencePhxMirror.Sync.Whiteboard do
  @moduledoc """
  A Confluence whiteboard, drawn from its document.

  Confluence's REST API has no export: a board is a canvas its own client paints,
  and the page's export view carries nothing but an unknown-macro placeholder.
  The board's *document*, however, is readable — over GraphQL, as
  `WHITEBOARD_DOC_FORMAT` — and it holds what the canvas is made of: a node per
  shape with a position, a size, a z-index and its words, plus the edges between
  them. That is enough to draw a still picture of the board, which is what a
  mirror is for.

  Two things this module refuses, loudly, rather than guessing:

    * a document whose `version` is not the one it knows. The format is internal
      and may change without notice, and a half-understood board drawn wrong is
      worse than a link to the real one.
    * a document with nothing to draw, which is a failure of the fetch or of the
      format rather than an empty board somebody meant to leave empty.

  Everything else is best effort: a node kind this module does not draw is
  skipped, and the words of a shape it cannot place are still drawn.
  """

  # The one document version this module was written against. When Confluence
  # moves it, the mirror falls back to the apology box and a link — the honest
  # answer until somebody reads the new shape.
  @version "2024-05-20_ALPHA"

  # Room around the drawing, so a shape on the edge does not touch the frame.
  @margin 40

  @doc """
  Inline SVG for a whiteboard document, or `:error` when it cannot be drawn.

      iex> svg(%{"version" => "2024-05-20_ALPHA", "nodes" => %{}})
      :error

      iex> svg(%{"version" => "1999-01-01", "nodes" => %{"a" => %{}}})
      :error
  """
  @spec svg(map()) :: {:ok, String.t()} | :error
  def svg(%{"version" => @version, "nodes" => nodes})
      when is_map(nodes) and map_size(nodes) > 0 do
    case drawable(nodes) do
      [] -> :error
      shapes -> {:ok, frame(shapes)}
    end
  end

  def svg(_document), do: :error

  @doc "Whether this module knows the document version it was handed."
  @spec known_version?(map()) :: boolean()
  def known_version?(%{"version" => @version}), do: true
  def known_version?(_document), do: false

  # A shape is what a board mostly is: a box with words in it. Anything else —
  # frames, connectors, drawings — is left to a later module rather than
  # guessed at.
  defp drawable(nodes) do
    nodes
    |> Map.values()
    |> Enum.filter(&(&1["type"] == "shape" and placed?(&1)))
    |> Enum.sort_by(&{&1["zIndex"] || 0, &1["id"]})
  end

  defp placed?(%{"geometry" => geometry}) when is_map(geometry), do: true
  defp placed?(_node), do: false

  defp frame(shapes) do
    {min_x, min_y, max_x, max_y} = bounds(shapes)
    width = max(max_x - min_x, 1) + @margin * 2
    height = max(max_y - min_y, 1) + @margin * 2

    [
      ~s(<svg class="mirror-whiteboard" viewBox="#{round(min_x - @margin)} #{round(min_y - @margin)} #{round(width)} #{round(height)}"),
      ~s( xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Whiteboard">),
      Enum.map(shapes, &shape/1),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  defp bounds(shapes) do
    shapes
    |> Enum.map(fn %{"geometry" => %{"position" => position, "size" => size}} ->
      x = number(position["x"])
      y = number(position["y"])
      {x, y, x + number(size["x"]), y + number(size["y"])}
    end)
    |> Enum.reduce(fn {x1, y1, x2, y2}, {ax1, ay1, ax2, ay2} ->
      {min(ax1, x1), min(ay1, y1), max(ax2, x2), max(ay2, y2)}
    end)
  end

  defp shape(%{"geometry" => %{"position" => position, "size" => size}} = node) do
    x = number(position["x"])
    y = number(position["y"])
    w = max(number(size["x"]), 1)
    h = max(number(size["y"]), 1)

    [
      "<g>",
      ~s(<rect x="#{round(x)}" y="#{round(y)}" width="#{round(w)}" height="#{round(h)}"),
      ~s( rx="8" fill="#{fill(node)}" stroke="#{stroke(node)}" />),
      text(node, x, y, w, h),
      "</g>"
    ]
  end

  # The words of a shape are an ADF document in a string; only its text runs
  # matter for a still, so the rest of the structure is walked and dropped.
  defp text(node, x, y, _w, h) do
    case lines(node["text"]) do
      [] ->
        []

      lines ->
        [
          ~s(<text x="#{round(x + 12)}" y="#{round(y + h / 2 + 5)}" ),
          ~s(font-size="14" font-family="ui-sans-serif, system-ui" fill="#{ink(node)}">),
          lines |> Enum.take(3) |> Enum.map(&escape/1) |> Enum.join(" "),
          "</text>"
        ]
    end
  end

  defp lines(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"type" => "doc"} = doc} -> doc |> words() |> Enum.reject(&(&1 == ""))
      _not_a_document -> [String.trim(text)]
    end
  end

  defp lines(_text), do: []

  defp words(%{"text" => text}) when is_binary(text), do: [String.trim(text)]
  defp words(%{"content" => content}) when is_list(content), do: Enum.flat_map(content, &words/1)
  defp words(_node), do: []

  defp fill(node) do
    case node["color"] do
      color when is_binary(color) -> palette(color)
      _no_colour -> "#ffffff"
    end
  end

  defp stroke(node) when is_map(node), do: "#dfe1e6"

  defp ink(_node), do: "#172b4d"

  # Confluence names its palette; a name this module does not know is drawn as
  # the neutral default rather than as an invented colour.
  @palette %{
    "light-blue" => "#deebff",
    "light-green" => "#e3fcef",
    "light-yellow" => "#fffae6",
    "light-red" => "#ffebe6",
    "light-purple" => "#eae6ff",
    "blue" => "#4c9aff",
    "green" => "#36b37e",
    "yellow" => "#ffab00",
    "red" => "#ff5630",
    "purple" => "#8777d9",
    "grey" => "#f4f5f7",
    "gray" => "#f4f5f7",
    "white" => "#ffffff"
  }

  defp palette(name) do
    case Map.get(@palette, name) do
      nil -> if hex?(name), do: name, else: "#ffffff"
      hex -> hex
    end
  end

  defp hex?(value), do: Regex.match?(~r/^#[0-9a-fA-F]{3,8}$/, value)

  defp number(value) when is_number(value), do: value
  defp number(value) when is_binary(value), do: parse_float(value)
  defp number(_value), do: 0

  defp parse_float(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
