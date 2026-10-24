defmodule ConfluencePhxMirrorWeb.ApiSwaggerTest do
  @moduledoc """
  `/api/docs/swagger` is Swagger UI over the document the mirror generates from
  its own router. These tests hold the page to that: the UI must be pointed at
  the served document (not a copy), and the bundle must come from this origin,
  because every screen wears a `script-src 'self'` policy.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  test "Swagger UI mounts the document the mirror serves", %{conn: conn} do
    html = conn |> get("/api/docs/swagger") |> html_response(200)

    assert html =~ ~s(id="swagger-ui")
    assert [_, spec_url] = Regex.run(~r/data-spec-url="([^"]+)"/, html)

    document = conn |> get(spec_url) |> json_response(200)
    assert document["openapi"] == "3.1.0"
    assert Map.has_key?(document["paths"], "/api/v1/spaces")
  end

  test "the bundle is served from this origin, as the page's policy requires", %{conn: conn} do
    conn = get(conn, "/api/docs/swagger")
    html = html_response(conn, 200)

    assert html =~ ~s(src="/assets/js/swagger.js")
    assert html =~ ~s(href="/assets/js/swagger.css")
    assert get_resp_header(conn, "content-security-policy") |> hd() =~ "script-src 'self'"
  end

  test "the widget keeps a light surface of its own", %{conn: conn} do
    html = conn |> get("/api/docs/swagger") |> html_response(200)

    # `.swagger-ui-frame` in app.css paints the white card Swagger UI's own grey
    # text needs; without it the widget is unreadable on a dark variant.
    assert html =~ "swagger-ui-frame"
  end

  test "in development the page names the administrator a request is sent as", %{conn: conn} do
    html = conn |> get("/api/docs/swagger") |> html_response(200)

    assert html =~ "Development mode"
    assert html =~ ConfluencePhxMirror.Accounts.Admins.bootstrap_email()
  end

  test "elsewhere it says cookies carry the reader and a token serves scripts", %{conn: conn} do
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)

    html = conn |> get("/api/docs/swagger") |> html_response(200)

    refute html =~ "Development mode"
    assert html =~ "carry this browser's cookies"
    assert html =~ ~s(href="/profile")
  end

  test "the readable page stays free of vendor JavaScript and points at the UI", %{conn: conn} do
    html = conn |> get("/api/docs") |> html_response(200)

    refute html =~ "/assets/js/swagger.js"
    assert html =~ ~s(href="/api/docs/swagger")
  end

  test "a deployment switches Swagger UI off together with the description", %{conn: conn} do
    previous = Application.get_env(:confluence_phx_mirror, :api_docs)
    Application.put_env(:confluence_phx_mirror, :api_docs, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :api_docs, previous) end)

    assert %{status: 404} = get(conn, "/api/docs/swagger")
  end
end
