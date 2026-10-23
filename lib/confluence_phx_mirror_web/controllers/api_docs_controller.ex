defmodule ConfluencePhxMirrorWeb.ApiDocsController do
  @moduledoc """
  The API description, for machines and for people.

  `/api/openapi.json` is the document itself — hand it to Postman, Insomnia,
  Redocly or an editor and the whole API is there. `/api/docs` renders the same
  document as a page, from the same source, so the two cannot disagree.

  Neither needs a token: an API nobody can discover is not much of a feature,
  and neither response touches the database. `CM_API_DOCS` turns both off at
  boot, which is why `OpenApi.enabled?/0` is checked here rather than in the
  router — a disabled surface answers `404`, it does not fail to route.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirrorWeb.Api.OpenApi

  def index(conn, _params) do
    when_enabled(conn, fn conn ->
      render(conn, :index,
        page_title: "API",
        sections: OpenApi.sections(),
        spec_url: "/api/openapi.json"
      )
    end)
  end

  def spec(conn, _params) do
    when_enabled(conn, fn conn ->
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> json(OpenApi.document())
    end)
  end

  defp when_enabled(conn, fun) do
    if OpenApi.enabled?() do
      fun.(conn)
    else
      conn
      |> put_status(404)
      |> text("API documentation is disabled on this mirror.")
      |> halt()
    end
  end
end
