defmodule ConfluencePhxMirrorWeb.Plugs.ProxyAuthTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :proxy_auth)
    previous_admin = Application.get_env(:confluence_phx_mirror, :auto_admin)

    Application.put_env(:confluence_phx_mirror, :proxy_auth, true)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)

    on_exit(fn ->
      Application.put_env(:confluence_phx_mirror, :proxy_auth, previous)
      Application.put_env(:confluence_phx_mirror, :auto_admin, previous_admin)
    end)

    :ok
  end

  test "an unknown identity header provisions an account", %{conn: conn} do
    conn = conn |> put_req_header("x-forwarded-email", "jane@example.com") |> get(~p"/")

    assert html_response(conn, 200)
    assert Accounts.get_user_by_email("jane@example.com")
  end

  test "the same identity reuses the account" do
    for _ <- 1..2 do
      build_conn()
      |> put_req_header("x-forwarded-email", "jane@example.com")
      |> get(~p"/")
    end

    assert [_user] = Accounts.list_users() |> Enum.filter(&(&1.email == "jane@example.com"))
  end

  test "the header is ignored when proxy auth is off", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :proxy_auth, false)

    conn = conn |> put_req_header("x-forwarded-email", "jane@example.com") |> get(~p"/")

    assert html_response(conn, 200)
    refute Accounts.get_user_by_email("jane@example.com")
  end

  test "a seeded administrator signing in through the proxy reaches the admin area", %{conn: conn} do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    conn = put_req_header(conn, "x-forwarded-email", "ops@example.com")

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Mirror dashboard"
  end
end
