defmodule ConfluencePhxMirrorWeb.ApiDocsController do
  @moduledoc """
  The API description, for machines and for people.

  `/api/openapi.json` is the document itself — hand it to Postman, Insomnia,
  Redocly or an editor and the whole API is there. `/api/docs` renders the same
  document as a page, from the same source, so the two cannot disagree;
  `/api/docs/swagger` is the same document in Swagger UI, for clicking through
  it. That last page is the only one that loads vendor JavaScript, which is why
  it is a page of its own.

  None of them needs a token: an API nobody can discover is not much of a
  feature, and none of the three responses touches the database. `CM_API_DOCS`
  turns all of them off at boot, which is why `OpenApi.enabled?/0` is checked
  here rather than in the router — a disabled surface answers `404`, it does not
  fail to route.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirrorWeb.Api.OpenApi

  def index(conn, _params) do
    when_enabled(conn, fn conn ->
      render(conn, :index,
        page_title: "API",
        sections: OpenApi.sections(),
        spec_url: "/api/openapi.json",
        swagger_url: "/api/docs/swagger"
      )
    end)
  end

  def swagger(conn, _params) do
    when_enabled(conn, fn conn ->
      render(conn, :swagger,
        page_title: "API · Swagger UI",
        swagger_ui: true,
        spec_url: "/api/openapi.json",
        readable_url: "/api/docs",
        # The page says what a request needs here. In development and test
        # `ApiAuth` assumes this administrator for an unauthenticated call, so
        # "Try it out" works without a token and the page must say so.
        auto_admin: Application.get_env(:confluence_phx_mirror, :auto_admin, false),
        admin_email: Admins.bootstrap_email()
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
