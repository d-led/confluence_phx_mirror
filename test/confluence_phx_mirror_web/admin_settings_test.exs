defmodule ConfluencePhxMirrorWeb.AdminSettingsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Settings

  setup do
    demo_snapshot!()
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "an administrator sets the theme every reader wears", %{conn: conn} do
    conn = sign_in(conn, admin_user())
    {:ok, view, html} = live(conn, ~p"/admin/settings")

    assert html =~ "Fresh blue"
    assert html =~ "Default"

    # Saving reloads the document, because the theme is an attribute of `<html>`.
    assert {:error, {:redirect, %{to: "/admin/settings"}}} =
             view |> element("#theme-form") |> render_submit(%{"theme" => "default"})

    page = conn |> get(~p"/") |> html_response(200)
    refute document_attributes(page) =~ "fresh-blue"
  end

  test "the reader keeps their variant whatever the theme is", %{conn: conn} do
    conn = sign_in(conn, admin_user())
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    view |> element("#theme-form") |> render_submit(%{"theme" => "fresh-blue"})

    html =
      conn
      |> Plug.Test.put_req_cookie("mirror_theme", "dark")
      |> get(~p"/")
      |> html_response(200)

    assert document_attributes(html) =~ ~s(data-theme="fresh-blue")
    assert document_attributes(html) =~ ~s(data-scheme="dark")
  end

  test "the page shows the configuration the mirror booted with", %{conn: conn} do
    {:ok, _view, html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    assert html =~ "Source &amp; sync"
    assert html =~ "CM_THEME"
    assert html =~ "Limits"
  end

  test "a member is sent home, not shown the page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(
               sign_in(conn, user_fixture(%{email: "member@example.com"})),
               ~p"/admin/settings"
             )
  end

  test "an anonymous reader is sent to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/session"}}} = live(conn, ~p"/admin/settings")
  end

  defp admin_user do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
