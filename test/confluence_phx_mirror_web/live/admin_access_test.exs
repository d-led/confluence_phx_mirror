defmodule ConfluencePhxMirrorWeb.AdminAccessTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Repo

  setup do
    demo_snapshot!()
    # Readers are anonymous unless a test signs them in.
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "an anonymous reader is sent to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/session"}}} = live(conn, ~p"/admin")
  end

  test "a member is sent back home", %{conn: conn} do
    conn = sign_in(conn, user_fixture(%{email: "member@example.com"}))

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
  end

  test "a seeded administrator opens the dashboard", %{conn: conn} do
    with_env(:admins, ["ops@example.com"])
    conn = sign_in(conn, user_fixture(%{email: "ops@example.com", role: "member"}))

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Mirror dashboard"
  end

  test "a member of the admin group opens the dashboard", %{conn: conn} do
    with_env(:admin_groups, ["confluence-admins"])

    user =
      user_fixture(%{email: "lead@example.com"})
      |> with_groups(["confluence-admins"])

    assert {:ok, _view, html} = live(sign_in(conn, user), ~p"/admin")
    assert html =~ "Mirror dashboard"
  end

  test "a seeded administrator may sign in even with self sign-up closed" do
    with_env(:admins, ["new-ops@example.com"])
    with_env(:self_signup, false)

    assert {:ok, :sent} = Accounts.request_login("new-ops@example.com")
    assert Accounts.get_user_by_email("new-ops@example.com")
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp with_groups(user, groups) do
    {:ok, user} = user |> User.identity_changeset(%{groups: groups}) |> Repo.update()
    user
  end

  defp with_env(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, key, previous) end)
  end
end
