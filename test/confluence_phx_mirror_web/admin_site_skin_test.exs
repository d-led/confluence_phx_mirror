defmodule ConfluencePhxMirrorWeb.AdminSiteSkinTest do
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
    :ok
  end

  test "an administrator pins a skin for every reader, and hands the choice back", %{conn: conn} do
    conn = sign_in(conn, admin_user())
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("button[phx-click=open_skin_dialog]") |> render_click()
    assert has_element?(view, "#site-skin-form")

    view
    |> element("#site-skin-form")
    |> render_submit(%{"name" => "fresh-blue"})

    assert render(view) =~ "Site skin set to Fresh blue"

    pinned = conn |> get(~p"/") |> html_response(200)
    assert pinned =~ ~s(data-theme="fresh-blue")
    refute pinned =~ ~s(href="/theme/dark")

    view |> element("button[phx-click=open_skin_dialog]") |> render_click()
    view |> element("#site-skin-form") |> render_submit(%{"name" => ""})

    assert render(view) =~ "Site skin cleared"

    freed = conn |> get(~p"/") |> html_response(200)
    assert freed =~ ~s(href="/theme/dark")
  end

  test "the dialog offers every skin and the choice back", %{conn: conn} do
    conn = sign_in(conn, admin_user())
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("button[phx-click=open_skin_dialog]") |> render_click()
    html = render(view)

    assert html =~ "Fresh blue"
    assert html =~ "Mirror"
    assert html =~ "Readers choose"
  end

  defp admin_user do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
