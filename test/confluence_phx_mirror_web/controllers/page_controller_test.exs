defmodule ConfluencePhxMirrorWeb.PageControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup %{conn: conn} do
    demo_snapshot!()
    # The home rail and the feeds list what a reader may open; these cases are
    # an administrator's, who sees the restricted spaces too.
    {:ok, conn: log_in_admin(conn)}
  end

  test "GET / renders the mirror home with spaces and freshness", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "mirror of the demo snapshot"
    assert html =~ "Engineering Handbook"
    assert html =~ "Product Hub"
    assert html =~ "Search the mirror"
    assert html =~ "Freshness"
  end

  test "the landing page searches from the top bar, where every other page does", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(document, "header #header-search-input")) == 1
    assert Enum.empty?(LazyHTML.query(document, "main #header-search-input"))
  end

  test "a page mirrored before emoticons were converted still shows them", %{conn: conn} do
    # The mirror stores the HTML it rendered at sync time. A body stored before
    # the renderer knew about emoticons still carries Confluence's own image,
    # which an anonymous reader cannot load; the page view converts it on the
    # way out, so no resync is needed for it to appear.
    space = space_fixture(%{key: "EMO", name: "Emoticons"})
    page = page_fixture(space, %{confluence_id: 9601, slug: "ship-it", title: "Ship it"})

    body = """
    <p>Ship it <img class="emoticon emoticon-tick" data-emoticon-name="tick" alt="(tick)"
                    src="https://dled.atlassian.net/wiki/images/icons/emoticons/check.png" /></p>
    """

    {:ok, _} = ConfluencePhxMirror.Mirror.update_rendered(page, %{body_export: body})

    html = conn |> get(~p"/spaces/EMO/pages/9601/ship-it") |> html_response(200)

    assert html =~ "Ship it ✅"
    refute html =~ "images/icons/emoticons/check.png"
  end

  test "a deep page collapses its breadcrumb into an ellipsis dropdown", %{conn: conn} do
    html = conn |> get("/spaces/ENG/pages/1205/Emergency+Revocation") |> html_response(200)

    assert html =~ "Emergency Revocation"
    assert html =~ "Certificate Rotation"
    # Five levels sit between the space's home page — which the space crumb
    # already represents, so it is not repeated — and the immediate parent.
    assert html =~ "Show 5 hidden levels"
    assert html =~ "Networking"
  end

  test "a shallow page keeps every breadcrumb inline", %{conn: conn} do
    html = conn |> get("/spaces/ENG/pages/1002/Architecture+Overview") |> html_response(200)

    assert html =~ "Getting Started"
    refute html =~ "hidden levels"
  end

  test "page timestamps reach the browser as UTC, ready for its own clock", %{conn: conn} do
    space = space_fixture(%{key: "CLOCK", name: "Clock Testimonies"})

    page_fixture(space, %{
      confluence_id: 9501,
      slug: "clocks",
      external_updated_at: ~U[2026-10-21 09:30:00Z]
    })

    html = conn |> get(~p"/spaces/CLOCK/pages/9501/clocks") |> html_response(200)

    assert html =~
             ~r/<time[^>]*datetime="2026-10-21T09:30:00Z"[^>]*data-local-time="datetime"[^>]*title="21 Oct 2026, 09:30 UTC"/

    # "Updated 3 hours ago" keeps its words; only the tooltip takes the instant.
    assert html =~ ~s(data-local-title)
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

  test "GET a page renders macro markup, labels and the original link", %{conn: conn} do
    html = conn |> get("/spaces/ENG/pages/1002/Architecture+Overview") |> html_response(200)

    assert html =~ "Architecture Overview"
    assert html =~ "confluence-content"
    assert html =~ "View original"
    assert html =~ "/labels/architecture"
    assert html =~ ~s(href="/attachments/ENG/1002/9001/diagram.svg")
  end

  test "a page whose body a sync has not reached yet says so", %{conn: conn} do
    space = space_fixture(%{key: "PENDING"})
    page_fixture(space, %{confluence_id: 9101, title: "Half imported", slug: "half-imported"})

    html = conn |> get(~p"/spaces/PENDING/pages/9101/half-imported") |> html_response(200)

    assert html =~ ~s(id="body-pending")
    assert html =~ "Body not mirrored yet"
    refute html =~ "confluence-content"
  end

  test "a page whose body arrived shows it without the pending notice", %{conn: conn} do
    space = space_fixture(%{key: "LANDED"})

    page_fixture(space, %{
      confluence_id: 9102,
      title: "Wholly imported",
      slug: "wholly-imported",
      body_export: "<p>Arrived</p>"
    })

    html = conn |> get(~p"/spaces/LANDED/pages/9102/wholly-imported") |> html_response(200)

    assert html =~ "confluence-content"
    assert html =~ "Arrived"
    refute html =~ "Body not mirrored yet"
  end

  test "a stale slug redirects to the canonical page URL", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/1002/old-name")
    assert redirected_to(conn) == "/spaces/ENG/pages/1002/Architecture+Overview"
  end

  describe "Confluence's own URL shape" do
    test "a plus-separated title is the canonical URL, not a redirect", %{conn: conn} do
      space = space_fixture(%{key: "LOAD013"})

      page =
        page_fixture(space, %{
          title: "API /v2: changelog? (draft) #2",
          slug: "API+v2+changelog+draft+2"
        })

      html =
        conn
        |> get("/spaces/LOAD013/pages/#{page.confluence_id}/API+v2+changelog+draft+2")
        |> html_response(200)

      assert html =~ "API /v2: changelog? (draft) #2"
    end

    test "a title with nothing slug-worthy is served by id alone", %{conn: conn} do
      space = space_fixture(%{key: "MFS"})
      page = page_fixture(space, %{title: "Обзор проекта", slug: ""})

      html = conn |> get("/spaces/MFS/pages/#{page.confluence_id}") |> html_response(200)

      assert html =~ "Обзор проекта"
    end

    test "that page still redirects a title-ish segment to the id-only URL", %{conn: conn} do
      space = space_fixture(%{key: "MFS"})
      page = page_fixture(space, %{title: "Обзор проекта", slug: ""})

      conn = get(conn, "/spaces/MFS/pages/#{page.confluence_id}/Обзор+проекта")

      assert redirected_to(conn) == "/spaces/MFS/pages/#{page.confluence_id}"
    end

    test "a space-encoded title resolves to the same page", %{conn: conn} do
      space = space_fixture(%{key: "LOAD013"})
      page = page_fixture(space, %{title: "LOAD01 Page 1044", slug: "LOAD01+Page+1044"})

      assert conn
             |> get("/spaces/LOAD013/pages/#{page.confluence_id}/LOAD01%20Page%201044")
             |> html_response(200) =~ "LOAD01 Page 1044"
    end
  end

  test "unknown pages return 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/ENG/pages/999999/missing") |> html_response(404)
    assert body =~ "That content is not mirrored"
  end

  test "a blog post renders under the space blog URL", %{conn: conn} do
    html = conn |> get("/spaces/PROD/blog/2001/Release+2+0") |> html_response(200)

    assert html =~ "Release 2.0"
    assert html =~ "Blog post"
    assert html =~ ~s(href="/spaces/PROD/blog")
  end

  test "a stale blog slug redirects to the canonical blog URL", %{conn: conn} do
    conn = get(conn, ~p"/spaces/PROD/blog/2001/old-release-notes")

    assert redirected_to(conn) == "/spaces/PROD/blog/2001/Release+2+0"
  end

  test "a page names its version in an etag and answers 304 to a repeat", %{conn: conn} do
    conn = get(conn, "/spaces/ENG/pages/1002/Architecture+Overview")
    assert [etag] = get_resp_header(conn, "etag")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=0, must-revalidate"]

    again =
      conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> get("/spaces/ENG/pages/1002/Architecture+Overview")

    assert again.status == 304
    assert again.resp_body == ""
  end

  test "a page is not served from the blog URL", %{conn: conn} do
    body = conn |> get("/spaces/ENG/blog/1002/Architecture+Overview") |> html_response(404)
    assert body =~ "That blog post is not mirrored"
  end

  test "a blog post opens at its own address, and a stale slug forwards to it", %{conn: conn} do
    space = space_fixture(%{key: "POSTS", name: "Release Notes"})
    post = page_fixture(space, %{title: "Release 2.0", type: "blogpost", slug: "Release+2+0"})
    path = "/spaces/POSTS/blog/#{post.confluence_id}"

    assert conn |> get("#{path}/Release+2+0") |> html_response(200) =~ "Release 2.0"

    assert conn |> get("#{path}/Release+1+0") |> redirected_to() == "#{path}/Release+2+0"
  end

  test "recently updated lists the newest content first, a window at a time", %{conn: conn} do
    html = conn |> get(~p"/recent") |> html_response(200)

    assert html =~ "Recently updated"
    assert html =~ "Architecture Overview"
    assert html =~ "Showing 1–25 · more results"

    second = conn |> get(~p"/recent?offset=25") |> html_response(200)

    assert second =~ "Release 2.0"
    assert second =~ "Showing 26–"
  end

  test "a change in the feed says what happened, where, and to whose page", %{conn: conn} do
    space = space_fixture(%{key: "FRESH", name: "Freshness Lab"})

    first_draft =
      page_fixture(space, %{
        confluence_id: 96_001,
        title: "First draft",
        version_number: 1,
        author_name: "Ada",
        body_text: "How the revocation list is built,\n\nand who signs it.",
        external_updated_at: ~U[2026-10-23 10:00:00Z]
      })

    revised =
      page_fixture(space, %{
        confluence_id: 96_002,
        title: "Second draft",
        version_number: 3,
        author_name: "Grace",
        external_updated_at: ~U[2026-10-23 09:00:00Z]
      })

    document = conn |> get(~p"/recent") |> html_response(200) |> LazyHTML.from_fragment()

    changes = row_text(document, first_draft)
    assert changes =~ "First draft"
    assert changes =~ "Freshness Lab"
    assert changes =~ "Ada"
    # A title says what a page is called; the row has width to spare for what it
    # says, with a paragraph's line breaks flattened into the one line.
    assert changes =~ "How the revocation list is built, and who signs it."

    hrefs = row(document, first_draft) |> LazyHTML.query("a") |> LazyHTML.attribute("href")
    assert [href] = hrefs
    assert href =~ "/spaces/FRESH/pages/96001"

    # Confluence counts versions: a page still at its first one was written,
    # not edited, and the feed is the one place that can say so.
    assert changes =~ "new"
    refute row_text(document, revised) =~ "new"
  end

  test "a long page is quoted in the feed, not copied into it", %{conn: conn} do
    space = space_fixture(%{key: "LONG", name: "Long Reads"})

    page =
      page_fixture(space, %{
        confluence_id: 96_010,
        title: "A very long read",
        body_text: String.duplicate("prose ", 500),
        external_updated_at: ~U[2026-10-23 12:00:00Z]
      })

    document = conn |> get(~p"/recent") |> html_response(200) |> LazyHTML.from_fragment()

    quoted = row_text(document, page)
    assert quoted =~ "prose prose"
    # The cut is shown as a cut: a row that stopped mid-sentence without saying
    # so would read as the author's own ending.
    assert quoted =~ "…"
  end

  defp row(document, page) do
    document |> LazyHTML.query("#recent-page-#{page.id}")
  end

  defp row_text(document, page) do
    document |> row(page) |> LazyHTML.text()
  end

  # The watch panel asks after the page and after its space, and the two answers
  # decide different halves of it: a reader watching one is not watching the
  # other.
  describe "the watch panel" do
    setup %{conn: conn} do
      {:ok, page} = ConfluencePhxMirror.Mirror.find_page(1002)
      reader = user_fixture()
      path = "/spaces/ENG/pages/1002/Architecture+Overview"

      %{conn: conn, page: page, reader: reader, path: path}
    end

    test "a reader watching the page is offered to stop, and the space on its own", ctx do
      {:ok, _} = ConfluencePhxMirror.Notifications.subscribe(ctx.reader, "page", ctx.page.id)

      html =
        ctx.conn
        |> init_test_session(%{user_id: ctx.reader.id})
        |> get(ctx.path)
        |> html_response(200)

      assert html =~ "Stop watching"
      refute html =~ "Watch this page"
      assert html =~ "Watch all of ENG"
      refute html =~ "Watching the whole space."
    end

    test "a reader watching the space is offered the page on its own", ctx do
      {:ok, _} =
        ConfluencePhxMirror.Notifications.subscribe(ctx.reader, "space", ctx.page.space_id)

      html =
        ctx.conn
        |> init_test_session(%{user_id: ctx.reader.id})
        |> get(ctx.path)
        |> html_response(200)

      assert html =~ "Watch this page"
      refute html =~ "Stop watching"
      assert html =~ "Watching the whole space."
    end
  end
end
