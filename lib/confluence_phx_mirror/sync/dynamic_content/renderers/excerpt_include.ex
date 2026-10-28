defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.ExcerptInclude do
  @moduledoc """
  *Excerpt Include*: the excerpt another page declares, not its whole body.

      <div class="mirror-macro" data-macro="excerpt-include" data-page="Architecture Overview"></div>

  A page declares its excerpt with the *Excerpt* macro, and Confluence's own
  export view already carries that region as `div.excerpt-macro` — so the mirror
  reads the region rather than deciding for itself where an excerpt starts. The
  region is then expanded as the page that declares it, exactly like an include,
  so a macro inside the excerpt answers as that page.

  A page that declares no excerpt says so. Including the whole page instead would
  be a different macro, and a page that quietly grew a paragraph every time
  somebody edited the source would be worse than a sentence saying why.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Included, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case title(attrs) do
      "" -> [Nodes.empty("This macro names no page, so there is nothing to include.")]
      title -> excerpt(title, context)
    end
  end

  defp excerpt(title, context) do
    with {:ok, page} <- context.source.page_by_title(context.page, title),
         {:ok, region} <- region(page),
         {:ok, nodes} <- Included.expand(region, context, page) do
      nodes
    else
      :error ->
        [Nodes.notice("The page this macro includes is not in the mirror, or not readable here.")]

      :no_excerpt ->
        [Nodes.notice("That page declares no excerpt for this macro to include.")]

      {:limit, reason} ->
        Included.notice(reason)
    end
  end

  defp region(page) do
    case page
         |> Map.get(:body_export)
         |> to_string()
         |> Floki.parse_fragment!()
         |> excerpt_nodes() do
      [] -> :no_excerpt
      nodes -> {:ok, Floki.raw_html(nodes)}
    end
  end

  defp excerpt_nodes(document) do
    case Floki.find(document, "div.excerpt-macro") do
      [{"div", _attrs, children} | _another] -> children
      [] -> []
    end
  end

  defp title(attrs), do: attrs |> Map.get("page", "") |> String.trim()
end
