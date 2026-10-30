defmodule ConfluencePhxMirrorWeb.ExportControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Demo

  setup do
    demo_snapshot!()
    :ok
  end

  test "downloads one page as Markdown", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/1002/export.md")

    assert conn.status == 200
    assert conn.resp_body =~ "## Overview"
    assert header(conn, "content-type") =~ "text/markdown"
    assert header(conn, "content-disposition") =~ "architecture_overview.md"

    assert [%{action: "page.exported", entity_id: "1002", metadata: %{"format" => "markdown"}}] =
             Audit.search(action: "page.exported")
  end

  test "downloads one page with the files it links to", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/1002/export.zip")

    assert conn.status == 200
    assert header(conn, "content-type") =~ "application/zip"
    assert header(conn, "content-disposition") =~ "architecture_overview_markdown_"

    # The ZIP is a different thing leaving the building than the Markdown.
    assert [%{metadata: %{"format" => "zip"}}] = Audit.search(action: "page.exported")
  end

  test "a page archive follows the page's own access rules", %{conn: conn} do
    body =
      conn
      |> get(~p"/spaces/ENG/pages/#{Demo.restricted_page()}/export.zip")
      |> html_response(404)

    assert body =~ "That page is not mirrored"
  end

  test "offers a space as a ZIP download", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/export.zip")

    assert conn.status == 200
    assert header(conn, "content-type") =~ "application/zip"
    assert header(conn, "content-disposition") =~ "engineering_handbook_markdown_"

    assert [%{action: "space.exported", entity_id: "ENG", metadata: %{"format" => "markdown"}}] =
             Audit.search(action: "space.exported")
  end

  test "offers a space as a static site", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/site.zip")

    assert conn.status == 200
    assert header(conn, "content-type") =~ "application/zip"
    assert header(conn, "content-disposition") =~ "engineering_handbook_site_"

    assert [%{metadata: %{"format" => "static site"}}] = Audit.search(action: "space.exported")
  end

  test "an unknown space is a 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/export.zip") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end

  test "an unknown space's site is a 404 too", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/site.zip") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end

  # An export is a copy leaving the building, so the log names who took it — and
  # says nothing about a download that was refused. The shapes are asserted on
  # the downloads themselves, above, which are the requests that pay for them.
  describe "the audit trail" do
    test "names the reader who asked, not just the fact", %{conn: conn} do
      reader = user_fixture(%{email: "ops@example.com"})

      conn
      |> log_in(reader)
      |> get(~p"/spaces/ENG/pages/1002/export.md")

      assert [%{actor_type: "user", actor_email: "ops@example.com"}] =
               Audit.search(action: "page.exported")
    end

    test "records a copy taken without a reader to name", %{conn: conn} do
      # A deployment in front of a proxy signs everyone in; one that does not
      # still hands out the file, and the trail says so rather than nothing.
      get(conn, ~p"/spaces/ENG/pages/1002/export.md")

      assert [%{actor_type: "system", actor_label: "anonymous reader"}] =
               Audit.search(action: "page.exported")
    end

    test "says nothing about a space that was never handed over", %{conn: conn} do
      conn |> get(~p"/spaces/NOPE/export.zip") |> html_response(404)

      assert Audit.search(action: "space.exported") == []
    end

    test "says nothing about a restricted page a reader was refused", %{conn: conn} do
      member = user_fixture(%{email: "member@example.com"})

      conn
      |> log_in(member)
      |> get(~p"/spaces/ENG/pages/#{Demo.restricted_page()}/export.zip")
      |> html_response(404)

      assert Audit.search(action: "page.exported") == []
    end
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> hd()
end
