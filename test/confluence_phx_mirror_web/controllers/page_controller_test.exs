defmodule ConfluencePhxMirrorWeb.PageControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "GET / renders the mirror home with spaces and freshness", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "mirror of the demo snapshot"
    assert html =~ "Engineering Handbook"
    assert html =~ "Product Hub"
    assert html =~ "Search the mirror"
    assert html =~ "Freshness"
  end

  test "a deep page collapses its breadcrumb into an ellipsis dropdown", %{conn: conn} do
    html = conn |> get(~p"/spaces/ENG/pages/1205/emergency-revocation") |> html_response(200)

    assert html =~ "Emergency Revocation"
    assert html =~ "Certificate Rotation"
    # Five levels sit between the space's home page — which the space crumb
    # already represents, so it is not repeated — and the immediate parent.
    assert html =~ "Show 5 hidden levels"
    assert html =~ "Networking"
  end

  test "a shallow page keeps every breadcrumb inline", %{conn: conn} do
    html = conn |> get(~p"/spaces/ENG/pages/1002/architecture-overview") |> html_response(200)

    assert html =~ "Getting Started"
    refute html =~ "hidden levels"
  end

  test "a page named like its space keeps its own crumb", %{conn: conn} do
    space = space_fixture(%{key: "GLOSS", name: "Glossary", homepage_confluence_id: 7001})

    page_fixture(space, %{confluence_id: 7001, title: "Glossary", slug: "glossary"})

    page_fixture(space, %{
      confluence_id: 7002,
      title: "Glossary",
      slug: "glossary-2",
      ancestors: [7001]
    })

    page_fixture(space, %{
      confluence_id: 7003,
      title: "Terms",
      slug: "terms",
      ancestors: [7001, 7002]
    })

    html = conn |> get(~p"/spaces/GLOSS/pages/7003/terms") |> html_response(200)

    # 7001 is the space's home page, so the space crumb stands for it; 7002 only
    # shares the space's name, so the trail must still name it.
    assert html =~ ~s(href="/spaces/GLOSS/pages/7002/glossary-2")
  end

  test "reader pages only allow scripts from the mirror itself", %{conn: conn} do
    conn = get(conn, ~p"/")

    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    assert policy =~ "connect-src 'self' ws: wss:"
    assert policy =~ "frame-ancestors 'none'"
    refute policy =~ "'unsafe-eval'"
  end

  test "GET /spaces/:key redirects to the space home page", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG")
    assert redirected_to(conn) == ~p"/spaces/ENG/pages/1000/engineering-handbook"
  end

  test "GET a page renders macro markup, labels and the original link", %{conn: conn} do
    html = conn |> get(~p"/spaces/ENG/pages/1002/architecture-overview") |> html_response(200)

    assert html =~ "Architecture Overview"
    assert html =~ "confluence-content"
    assert html =~ "View original"
    assert html =~ "/labels/architecture"
    assert html =~ ~s(href="/attachments/ENG/1002/9001/diagram.svg")
  end

  test "a stale slug redirects to the canonical page URL", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/1002/old-name")
    assert redirected_to(conn) == ~p"/spaces/ENG/pages/1002/architecture-overview"
  end

  test "unknown pages return 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/ENG/pages/999999/missing") |> html_response(404)
    assert body =~ "That content is not mirrored"
  end

  test "a blog post renders under the space blog URL", %{conn: conn} do
    html = conn |> get(~p"/spaces/PROD/blog/2001/release-2-0") |> html_response(200)

    assert html =~ "Release 2.0"
    assert html =~ "Blog post"
    assert html =~ ~s(href="/spaces/PROD/blog")
  end

  test "a stale blog slug redirects to the canonical blog URL", %{conn: conn} do
    conn = get(conn, ~p"/spaces/PROD/blog/2001/old-release-notes")

    assert redirected_to(conn) == ~p"/spaces/PROD/blog/2001/release-2-0"
  end

  test "a page is not served from the blog URL", %{conn: conn} do
    body = conn |> get(~p"/spaces/ENG/blog/1002/architecture-overview") |> html_response(404)
    assert body =~ "That blog post is not mirrored"
  end

  test "recently updated lists the newest content first", %{conn: conn} do
    html = conn |> get(~p"/recent") |> html_response(200)

    assert html =~ "Recently updated"
    assert html =~ "Architecture Overview"
    assert html =~ "Release 2.0"
  end
end
