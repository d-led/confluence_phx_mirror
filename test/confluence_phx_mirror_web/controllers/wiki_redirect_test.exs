defmodule ConfluencePhxMirrorWeb.WikiRedirectTest do
  @moduledoc """
  A Confluence link pointed at this mirror still lands on the page: the `/wiki`
  prefix is dropped, the id decides which page it is, and the title part of the
  URL — Confluence writes `Title+With+Pluses` — costs at most a redirect to the
  canonical slug.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  test "a Confluence page URL keeps the page behind it", %{conn: conn} do
    space = space_fixture(%{key: "LOAD013"})
    page = page_fixture(space, %{title: "LOAD01 Page 1044"})

    conn = get(conn, "/wiki/spaces/LOAD013/pages/#{page.confluence_id}/LOAD01+Page+1044")

    assert redirected_to(conn) ==
             "/spaces/LOAD013/pages/#{page.confluence_id}/LOAD01+Page+1044"
  end

  test "the query string survives the prefix", %{conn: conn} do
    conn = get(conn, "/wiki/search?q=rate")

    assert redirected_to(conn) == "/search?q=rate"
  end

  test "the bare prefix is the mirror's root", %{conn: conn} do
    assert conn |> get("/wiki") |> redirected_to() == "/"
  end

  test "the Confluence-compatible API is not redirected", %{conn: conn} do
    space = space_fixture(%{key: "ENG"})
    _page = page_fixture(space, %{title: "Architecture"})

    conn = get(conn, "/wiki/rest/api/content?limit=5")

    assert json_response(conn, 200)["results"] != []
  end
end
