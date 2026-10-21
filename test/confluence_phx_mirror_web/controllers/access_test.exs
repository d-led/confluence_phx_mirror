defmodule ConfluencePhxMirrorWeb.AccessTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

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
    assert conn |> get(~p"/spaces/ENG/pages/1003/macros-gallery") |> html_response(404)
  end

  test "a space restricted to signed-in users is not found and not listed", %{conn: conn} do
    assert conn |> get(~p"/spaces/PROD") |> html_response(404)

    body = conn |> get(~p"/spaces") |> html_response(200)
    refute body =~ "Product Hub"
  end

  test "an open page is still served to anonymous readers", %{conn: conn} do
    body = conn |> get(~p"/spaces/ENG/pages/1002/architecture-overview") |> html_response(200)
    assert body =~ "Architecture Overview"
  end
end
