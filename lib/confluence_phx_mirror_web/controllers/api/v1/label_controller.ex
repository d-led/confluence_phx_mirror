defmodule ConfluencePhxMirrorWeb.Api.V1.LabelController do
  @moduledoc "Label listing with page counts."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Mirror

  def index(conn, _params) do
    results =
      for {name, count} <- Mirror.list_labels() do
        %{"name" => name, "prefix" => "global", "pageCount" => count}
      end

    json(conn, %{
      "results" => results,
      "size" => length(results),
      "_links" => %{"base" => ConfluencePhxMirrorWeb.Endpoint.url()}
    })
  end
end
