defmodule ConfluencePhxMirrorWeb.AdminSettingsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    # Readers are anonymous unless a test signs them in.
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "an administrator reads the configuration the mirror booted with", %{conn: conn} do
    html =
      conn
      |> sign_in(admin_conn_user())
      |> get(~p"/admin/settings")
      |> html_response(200)

    assert html =~ "Settings"
    assert html =~ "Site skin"
    assert html =~ "atlassian-cloud"
    assert html =~ "CM_SITE_SKIN"
    assert html =~ "Signed in as"
  end

  test "a secret is reported as configured, never printed", %{conn: conn} do
    with_env(:webhooks, secret: "super-secret-value", require_signature: true)

    html =
      conn
      |> sign_in(admin_conn_user())
      |> get(~p"/admin/settings")
      |> html_response(200)

    assert html =~ "configured"
    refute html =~ "super-secret-value"
  end

  test "the tabs reach every admin section", %{conn: conn} do
    html =
      conn
      |> sign_in(admin_conn_user())
      |> get(~p"/admin/settings")
      |> html_response(200)

    for path <-
          ~w(/admin /admin/sync-log /admin/webhooks /admin/audit /admin/users /admin/settings) do
      assert html =~ ~s(href="#{path}")
    end
  end

  test "a member is sent home, not shown the page", %{conn: conn} do
    conn =
      conn
      |> sign_in(user_fixture(%{email: "member@example.com"}))
      |> get(~p"/admin/settings")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Administrator access required."
  end

  test "an anonymous reader is sent to sign in", %{conn: conn} do
    conn = get(conn, ~p"/admin/settings")

    assert redirected_to(conn) == "/session"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Please sign in."
  end

  defp admin_conn_user do
    with_env(:admins, ["ops@example.com"])
    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp with_env(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, key, previous) end)
  end
end
