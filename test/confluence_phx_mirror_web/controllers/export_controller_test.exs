defmodule ConfluencePhxMirrorWeb.ExportControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "downloads one page as Markdown", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/pages/1002/export.md")

    assert conn.status == 200
    assert conn.resp_body =~ "## Overview"
    assert header(conn, "content-type") =~ "text/markdown"
    assert header(conn, "content-disposition") =~ "Architecture Overview.md"
  end

  test "offers a space as a ZIP download", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/export.zip")

    assert conn.status == 200
    assert header(conn, "content-type") =~ "application/zip"
    assert header(conn, "content-disposition") =~ "Engineering Handbook.zip"
  end

  test "offers a space as a static site", %{conn: conn} do
    conn = get(conn, ~p"/spaces/ENG/site.zip")

    assert conn.status == 200
    assert header(conn, "content-type") =~ "application/zip"
    assert header(conn, "content-disposition") =~ "Engineering Handbook site.zip"
  end

  test "an unknown space is a 404", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/export.zip") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end

  test "an unknown space's site is a 404 too", %{conn: conn} do
    body = conn |> get(~p"/spaces/NOPE/site.zip") |> html_response(404)
    assert body =~ "Space NOPE is not mirrored"
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> hd()
end
