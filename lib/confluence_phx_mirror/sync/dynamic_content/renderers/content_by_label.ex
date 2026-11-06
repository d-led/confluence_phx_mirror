defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.ContentByLabel do
  @moduledoc """
  *Content by Label*: the pages carrying a label, newest first.

      <div class="mirror-macro" data-macro="content-by-label"
           data-labels="runbook,incident" data-match="any" data-limit="10"
           data-space="ENG"></div>

  The listing is the mirror's own query, so a page is named only when the
  readers of the page carrying the macro may open it — the catalogue on an open
  page never advertises a restricted one.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case Attributes.list(attrs, "labels") do
      # Nothing to ask: an empty query is not a question, and the macro can say
      # what it means without one.
      [] -> [Nodes.empty("The macro names no label, so there is nothing to list.")]
      labels -> list(labels, attrs, context)
    end
  end

  defp list(labels, attrs, context) do
    pages =
      context.source.pages_by_label(context.page, labels,
        match: match(attrs),
        limit: Attributes.int(attrs, "limit", 10, 1..50),
        space: space(attrs)
      )

    case pages do
      [] ->
        [Nodes.empty("No content carries these labels yet.")]

      pages ->
        [Nodes.heading("Content by label: " <> Enum.join(labels, ", ")), Nodes.page_list(pages)]
    end
  end

  defp match(%{"match" => "any"}), do: :any
  defp match(_attrs), do: :all

  defp space(attrs), do: Map.get(attrs, "space")
end
