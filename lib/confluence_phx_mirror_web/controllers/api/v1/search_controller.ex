defmodule ConfluencePhxMirrorWeb.Api.V1.SearchController do
  @moduledoc """
  Structured search for the v1 API.

  Accepts the same filters as the UI: `q`, `space`, `label`, `type`, `creator`,
  `ancestor`, `updated` (`7d`, `30d`, `90d`, `365d` or an ISO date), plus
  `start`/`limit`. Text queries search every indexed field and support
  uppercase `AND`/`OR`/`NOT`, parentheses, quoted phrases and prefix matching.
  Raw CQL is not exposed here; `/wiki/rest/api/search` keeps it for Confluence
  compatibility.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror.Search
  alias ConfluencePhxMirror.Mirror.Search.Filters
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter

  def index(conn, params) do
    filters = Filters.normalise(params)

    if empty?(filters) do
      conn
      |> put_status(400)
      |> json(%{
        error: "missing_query",
        message: "Provide q and/or one of: space, label, type, creator, ancestor, updated."
      })
    else
      start = parse_int(params["start"], 0)
      limit = params["limit"] |> parse_int(25) |> min(100) |> max(1)

      case Search.structured(filters, start: start, limit: limit) do
        {:ok, results, _terms} ->
          results = Authorization.readable_results(conn.assigns.current_scope, results)

          items =
            Enum.map(results, fn result ->
              result.page
              |> Presenter.summary()
              |> Map.put("snippet", result.snippet)
              |> Map.put("rank", result.rank)
            end)

          body =
            Presenter.list(items, start: start, limit: limit, total: nil, path: "/api/v1/search")
            |> Map.put("filters", Map.reject(filters, fn {_key, value} -> value in [nil, ""] end))

          json(conn, body)

        {:error, message} ->
          conn |> put_status(400) |> json(%{error: "invalid_query", message: message})
      end
    end
  end

  defp empty?(filters) do
    filters["q"] in [nil, ""] and
      Enum.all?(Filters.field_keys(), &(filters[&1] in [nil, ""]))
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {number, _} -> number
      :error -> default
    end
  end
end
