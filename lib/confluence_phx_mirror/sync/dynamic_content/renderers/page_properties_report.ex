defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.PagePropertiesReport do
  @moduledoc """
  *Page Properties Report*: a table of the properties pages declare.

      <div class="mirror-macro" data-macro="page-properties-report"
           data-space="ENG" data-columns="Owner,Status"></div>

  The properties are what `Page Properties` macros put into a page's
  `properties` during the sync, so the report costs one query and no body
  parsing. Rows for pages the host's readers may not open are left out.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    report =
      context.source.property_report(
        context.page,
        space(attrs),
        Attributes.list(attrs, "columns")
      )

    case report.rows do
      [] -> [Nodes.empty("No page in this space declares properties yet.")]
      rows -> [Nodes.heading("Page properties report"), table(report.columns, rows)]
    end
  end

  defp space(attrs), do: Map.get(attrs, "space")

  defp table(columns, rows) do
    {"table", [{"class", "confluenceTable mirror-dynamic-report"}],
     [
       {"thead", [], [{"tr", [], Enum.map(["Page" | columns], &{"th", [], [&1]})}]},
       {"tbody", [], Enum.map(rows, &row(&1, columns))}
     ]}
  end

  defp row(%{page: page, values: values}, columns) do
    cells = Enum.map(columns, fn column -> {"td", [], [Map.get(values, column) || "—"]} end)

    {"tr", [],
     [
       {"td", [],
        [
          {"a",
           [{"href", URLs.content_path(page.space.key, page)}, {"class", "mirror-dynamic-link"}],
           [page.title]}
        ]}
       | cells
     ]}
  end
end
