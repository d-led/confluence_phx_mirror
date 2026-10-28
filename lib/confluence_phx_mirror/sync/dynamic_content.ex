defmodule ConfluencePhxMirror.Sync.DynamicContent do
  @moduledoc """
  Resolves Confluence's browser-only macros into static HTML at sync time.

  Confluence renders macros such as *Content by Label*, *Table of Contents* and
  *Page Properties Report* in the browser, so `export_view` only carries a
  placeholder. A static mirror cannot run that JavaScript, so it resolves these
  macros against its own data and bakes the result into the page body. The output
  is ordinary HTML: searchable, printable, and needing no client-side code.

  A placeholder is a `div` carrying `class="mirror-macro"` and `data-macro`:

      <div class="mirror-macro" data-macro="content-by-label"
           data-labels="runbook,incident" data-match="all" data-limit="10"></div>

      <div class="mirror-macro" data-macro="toc" data-min-level="2"></div>

  This module finds the markers, works out what the body itself offers (its
  headings), and hands each marker to its renderer; the macros themselves live in
  `Sync.DynamicContent.Renderers`, one module per name, and `Registry` says which
  name is which. A macro the mirror does not know renders a notice instead of
  disappearing silently.

  The marker element is kept and its children replaced, so expanding an already
  expanded body is safe — that is how `Sync` refreshes dependents after a page
  changes, without a dependency graph or recursion.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes, Registry, Source}

  @doc """
  Expands every dynamic macro marker in `html` for the page it belongs to.

  The context carries the page, because a listing baked in at sync time is shown
  to every reader of that page and may only name content they may open
  themselves — a rule the content port applies, not each macro
  (`Sync.DynamicContent.Source`).

  A caller may name the port (`%{space: space, page: page, source: StubContent}`),
  which is how a macro is tested without a database; production leaves it out.
  """
  @spec expand(String.t(), %{
          optional(:source) => module(),
          optional(:depth) => non_neg_integer(),
          optional(:seen) => [integer()],
          space: term(),
          page: term()
        }) :: String.t()
  def expand(html, %{space: space, page: page} = given) when is_binary(html) do
    document = Floki.parse_fragment!(html)

    context = %Context{
      space: space,
      page: page,
      headings: headings(document),
      source: Map.get(given, :source, Source.Mirror),
      depth: Map.get(given, :depth, 0),
      seen: Map.get(given, :seen, [page.id])
    }

    document
    |> Floki.traverse_and_update(&resolve(&1, context))
    |> Floki.raw_html()
  end

  def expand(html, _context), do: html

  @doc "Every heading the body offers a table of contents, in document order."
  @spec headings(Floki.html_tree()) :: [Context.heading()]
  def headings(document) do
    document
    |> Floki.find("h1, h2, h3, h4, h5, h6")
    |> Enum.flat_map(&heading/1)
  end

  defp heading({tag, attrs, children}) do
    with level when is_integer(level) <- level(tag),
         id when is_binary(id) and id != "" <- attr(attrs, "id"),
         text when text != "" <- children |> Floki.text() |> String.trim() do
      [%{level: level, id: id, text: text}]
    else
      _ -> []
    end
  end

  defp heading(_node), do: []

  defp level(<<"h", digit>>) when digit in ?1..?6, do: digit - ?0
  defp level(_tag), do: nil

  defp resolve({"div", attrs, _children} = node, context) do
    if marker?(attrs), do: {"div", attrs, contents(attrs, context)}, else: node
  end

  defp resolve(node, _context), do: node

  defp contents(attrs, context) do
    case Registry.fetch(attr(attrs, "data-macro")) do
      {:ok, renderer} ->
        renderer.render(parameters(attrs), context)

      :error ->
        [
          Nodes.notice(
            "Dynamic macro #{inspect(attr(attrs, "data-macro"))} is not supported by the mirror."
          )
        ]
    end
  end

  # `data-labels` is what a renderer calls `labels`: a macro never parses HTML.
  defp parameters(attrs) do
    for {"data-" <> name, value} <- attrs, into: %{}, do: {name, value}
  end

  defp marker?(attrs), do: "mirror-macro" in classes(attrs)

  defp classes(attrs), do: attrs |> attr("class") |> to_string() |> String.split(" ", trim: true)

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
