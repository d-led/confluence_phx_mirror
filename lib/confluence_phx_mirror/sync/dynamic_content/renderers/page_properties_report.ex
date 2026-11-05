defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.PagePropertiesReport do
  @moduledoc """
  *Page Properties Report*: a table of the properties pages declare.

      <div class="mirror-macro" data-macro="page-properties-report"
           data-space="ENG" data-columns="Owner,Status" data-limit="25"></div>

  The properties are what `Page Properties` macros put into a page's
  `properties` during the sync, so the report costs one query and no body
  parsing. Rows for pages the host's readers may not open are left out.

  A space carries one row per page that declares properties, so on a large
  space the report is the whole catalogue. It is read as one window instead —
  fifty rows unless the marker's `limit` asks for another number.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    report =
      context.source.property_report(
        context.page,
        space(attrs),
        Attributes.list(attrs, "columns"),
        limit: Attributes.int(attrs, "limit", 50, 1..200)
      )

    case report.rows do
      [] -> [Nodes.empty("No page in this space declares properties yet.")]
      rows -> [Nodes.heading("Page properties report"), table(report.columns, rows)]
    end
  end

  defp space(attrs), do: Map.get(attrs, "space")

  defp table(columns, rows) do
    Nodes.table(["Page" | columns], Enum.map(rows, &cells(&1, columns)))
  end

  defp cells(%{page: page, values: values}, columns) do
    [Nodes.link(page) | Enum.map(columns, &[Map.get(values, &1) || "—"])]
  end
end
