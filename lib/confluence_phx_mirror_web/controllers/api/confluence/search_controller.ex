defmodule ConfluencePhxMirrorWeb.Api.Confluence.SearchController do
  @moduledoc """
  Confluence-compatible search endpoint (`?cql=`).

  This is the one place raw CQL remains public, because that is the contract of
  `/wiki/rest/api/content/search`. The reader UI and `/api/v1/search` use the
  structured filter API instead.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror.Search
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter

  def index(conn, params) do
    cql = params["cql"]

    if is_binary(cql) and String.trim(cql) != "" do
      start = parse_int(params["start"], 0)
      limit = params["limit"] |> parse_int(25) |> min(100) |> max(1)

      case Search.search(cql, start: start, limit: limit) do
        {:ok, results} ->
          results = Authorization.readable_results(conn.assigns.current_scope, results)

          items =
            Enum.map(results, fn result ->
              result.page
              |> Presenter.summary()
              |> Map.put("snippet", result.snippet)
              |> Map.put("rank", result.rank)
              |> Map.put("comment", Presenter.search_comment(result.comment))
            end)

          body =
            Presenter.list(items,
              start: start,
              limit: limit,
              total: nil,
              path: "/wiki/rest/api/content/search"
            )
            |> Map.put("cql", cql)

          json(conn, body)

        {:error, message} ->
          conn |> put_status(400) |> json(%{error: "invalid_cql", message: message})
      end
    else
      conn
      |> put_status(400)
      |> json(%{error: "missing_cql", message: "The Confluence search endpoint requires cql."})
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {number, _} -> number
      :error -> default
    end
  end
end
