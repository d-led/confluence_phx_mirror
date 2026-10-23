defmodule ConfluencePhxMirrorWeb.AccessTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror

  setup do
    demo_snapshot!()
    # Readers are anonymous unless a test signs them in; administrators bypass
    # every permission check.
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "a page restricted to a group is not found for anonymous readers", %{conn: conn} do
    assert conn
           |> get(~p"/spaces/ENG/pages/#{Demo.restricted_page()}/#{Demo.restricted_page_slug()}")
           |> html_response(404)
  end

  test "a space restricted to signed-in users is not found and not listed", %{conn: conn} do
    assert conn |> get(~p"/spaces/PROD") |> html_response(404)

    body = conn |> get(~p"/spaces") |> html_response(200)
    refute body =~ "Product Hub"
  end

  test "a restricted space's icon is not served either", %{conn: conn} do
    blob_key = Key.space_icon("PROD", "image/svg+xml")
    {:ok, ^blob_key} = Store.put(blob_key, "<svg/>")

    {:ok, _space} =
      Mirror.upsert_space(%{
        key: "PROD",
        name: "Product Hub",
        icon_blob_key: blob_key,
        icon_media_type: "image/svg+xml"
      })

    assert conn |> get(~p"/spaces/PROD/icon") |> response(404) == "This space has no icon."
  end

  test "an open page is still served to anonymous readers", %{conn: conn} do
    body =
      conn
      |> get(~p"/spaces/ENG/pages/#{Demo.open_page()}/#{Demo.open_page_slug()}")
      |> html_response(200)

    assert body =~ "Architecture Overview"
  end

  test "the space catalog lists only pages the reader may open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/spaces/ENG/pages")

    assert has_element?(view, "a[href^='/spaces/ENG/pages/#{Demo.open_page()}']")
    refute has_element?(view, "a[href^='/spaces/ENG/pages/#{Demo.restricted_page()}']")
  end

  test "the home rail does not advertise a restricted space", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "Engineering Handbook"
    refute body =~ "Product Hub"
  end
end
