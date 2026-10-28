defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Toc do
  @moduledoc """
  *Table of Contents*: the page's own headings, as a nested list of anchors.

      <div class="mirror-macro" data-macro="toc" data-min-level="2"></div>

  Confluence renders this macro in the browser from the headings it finds, and
  `export_view` carries only the placeholder. A static mirror has the headings —
  they are in the body it is expanding, ids and all — so the list can be built
  once at sync time and needs no client-side code.

  Only the page's own headings are listed, never the headings of a page it
  includes, and the list itself carries no headings, so re-expanding an expanded
  body yields the same list.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{headings: headings}) do
    min_level = Attributes.int(attrs, "min-level", 1, 1..6)
    max_level = Attributes.int(attrs, "max-level", 6, 1..6)
    listed = Enum.filter(headings, &(&1.level in min_level..max_level))

    case listed do
      [] -> [Nodes.empty("This page has no headings to list.")]
      [first | _] -> [Nodes.heading("On this page"), nested_list(listed, first.level)]
    end
  end

  defp nested_list(headings, level), do: {"ul", [{"class", "mirror-toc"}], items(headings, level)}

  # A heading's own level decides the list it opens, so an h2 followed by an h4
  # nests once rather than inventing an empty h3 list between them.
  defp items([%{level: level} = heading | rest], level) do
    {deeper, rest} = Enum.split_while(rest, &(&1.level > level))

    [{"li", [], [anchor(heading) | deeper_list(deeper)]} | items(rest, level)]
  end

  defp items(_headings, _level), do: []

  defp deeper_list([]), do: []

  defp deeper_list([%{level: level} | _] = headings), do: [nested_list(headings, level)]

  defp anchor(heading) do
    {"a", [{"href", "#" <> heading.id}, {"class", "mirror-dynamic-link"}], [heading.text]}
  end
end
