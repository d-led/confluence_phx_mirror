defmodule ConfluencePhxMirrorWeb.Api.V1.LabelController do
  @moduledoc "Label listing with page counts, counted over what the caller may read."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Catalog

  def index(conn, _params) do
    results =
      for %{name: name, pages: count} <- Catalog.label_counts(conn.assigns.current_scope) do
        %{"name" => name, "prefix" => "global", "pageCount" => count}
      end

    json(conn, %{
      "results" => results,
      "size" => length(results),
      "_links" => %{"base" => ConfluencePhxMirrorWeb.Endpoint.url()}
    })
  end
end
