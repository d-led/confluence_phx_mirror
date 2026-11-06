defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.PageProperties do
  @moduledoc """
  *Page properties*: the key/value table a page declares for its own reports.

      <div class="mirror-macro" data-macro="pageproperties"></div>

  Confluence does not expand this macro for a reader without a browser, so the
  export view carries only the unknown-macro widget — while the values the page
  declares are in its storage, and the mirror already reads them out to feed the
  property reports. The macro asks the port about its own page, because the
  table a page declares belongs to that page.

  Both layouts a person can build — a heading column down the left, a heading
  row across the top — describe the same pairs of key and value, and both are
  drawn one property to a line.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @impl true
  def render(_attrs, %Context{} = context) do
    case context.source.page_properties(context.page) do
      [] -> [Nodes.empty("This page declares no properties.")]
      properties -> [table(properties)]
    end
  end

  defp table(properties) do
    {"table", [{"class", "confluenceTable mirror-page-properties"}],
     [{"tbody", [], Enum.map(properties, &row/1)}]}
  end

  defp row(%{key: key, value: value}) do
    {"tr", [],
     [{"th", [{"class", "confluenceTh"}], [key]}, {"td", [{"class", "confluenceTd"}], [value]}]}
  end
end
