defmodule ConfluencePhxMirrorWeb.FaviconTest do
  @moduledoc """
  The tab icon has to be the one name a browser can actually fetch.

  A release configures a cache manifest, and the route helper then answers with
  a digested name for any static path it knows. `Plug.Static` serves a top-level
  file only under the exact name `static_paths/0` allows: `/assets/…` and
  `/images/…` survive because their first segment is an allowed directory, but a
  file at the root has only itself, so the digested icon 404s and every tab
  falls back to a blank page. The test suite runs without a manifest, so this
  pins the invariant that keeps the release right rather than the symptom.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  test "the icon the layout names is served, under the name a browser asks for", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert ["/favicon.ico"] = icons(html)

    served = get(conn, "/favicon.ico")
    assert served.status == 200
    assert get_resp_header(served, "content-type") == ["image/vnd.microsoft.icon"]
    assert byte_size(served.resp_body) > 0
  end

  defp icons(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter("link[rel=icon]")
    |> LazyHTML.attribute("href")
  end
end
