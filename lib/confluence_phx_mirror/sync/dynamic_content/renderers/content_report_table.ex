defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.ContentReportTable do
  @moduledoc """
  *Content Report Table*: a table of whatever a CQL query selects.

      <div class="mirror-macro" data-macro="content-report-table"
           data-cql="label = runbook order by lastmodified desc limit 20"></div>

  This is Confluence's own way of putting a query on a page, and the mirror has a
  CQL parser for the queries its search box accepts, so the report is that
  parser's answer rather than a second one. The plugin already gets the operators
  the macro expects — `=`, `~`, `in`, `now()` — which is why it was worth writing
  a parser at all.

  A query the mirror refuses (a field it never stored, a per-person function, a
  typo) is shown as the reason: an empty table would look like "nothing matched",
  and that is a different, and untrue, answer.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case attrs |> Map.get("cql", "") |> String.trim() do
      "" -> [Nodes.empty("This report names no CQL query, so it lists nothing.")]
      cql -> report(cql, context)
    end
  end

  defp report(cql, context) do
    case context.source.search(context.page, cql) do
      {:ok, []} -> [Nodes.empty("No content matches this report's query.")]
      {:ok, pages} -> [table(pages)]
      {:error, reason} -> [Nodes.notice("This report's query cannot be answered: " <> reason)]
    end
  end

  defp table(pages) do
    Nodes.table(["Title", "Space", "Last modified"], Enum.map(pages, &row/1))
  end

  defp row(page), do: [Nodes.link(page), [page.space.key], [Nodes.updated(page)]]
end
