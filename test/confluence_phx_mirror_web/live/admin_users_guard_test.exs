defmodule ConfluencePhxMirrorWeb.Live.AdminUsersGuardTest do
  @moduledoc """
  The users screen must not let an administrator lock the mirror out: the
  account that is the last one able to administer cannot be switched off or
  demoted from here, and the screen says why.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User

  setup do
    # No automatic administrator: this test needs to know exactly who is left.
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "the last administrator sees the controls locked", %{conn: conn} do
    admin = user_fixture(%{email: "solo@example.com", role: "admin"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/users")

    assert has_element?(view, "#role-locked-#{admin.id}", "Last admin")
    assert has_element?(view, "#toggle-locked-#{admin.id}")
    refute has_element?(view, "#toggle-#{admin.id}")
    assert has_element?(view, "#ban-locked-#{admin.id}", "Last admin")
    refute has_element?(view, "#ban-#{admin.id}")
  end

  test "the last administrator is offered no Delete the server would refuse", %{conn: conn} do
    admin = user_fixture(%{email: "solo@example.com", role: "admin"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/users")

    assert has_element?(view, "#delete-#{admin.id}[disabled]")
  end

  test "a bootstrap administrator who is alone is not offered Delete either", %{conn: conn} do
    bootstrap = user_fixture(%{email: "admin@localhost", role: "admin"})

    {:ok, view, _html} = live(sign_in(conn, bootstrap), ~p"/admin/users")

    assert has_element?(view, "#delete-#{bootstrap.id}[disabled]")
  end

  test "the last administrator cannot be banned even if the event arrives", %{conn: conn} do
    admin = user_fixture(%{email: "solo@example.com", role: "admin"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/users")

    html = render_submit(view, "ban", %{"user_id" => to_string(admin.id)})

    assert html =~ "last administrator"
    refute User.banned?(Accounts.get_user(admin.id))
  end

  test "the last administrator stays one even if the event arrives", %{conn: conn} do
    admin = user_fixture(%{email: "solo@example.com", role: "admin"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/users")

    html =
      render_submit(view, "change_role", %{"user_id" => to_string(admin.id), "role" => "member"})

    assert html =~ "last administrator"
    assert Accounts.get_user(admin.id).role == "admin"
  end

  test "an administrator with a colleague can still step down", %{conn: conn} do
    admin = user_fixture(%{email: "solo@example.com", role: "admin"})
    user_fixture(%{email: "deputy@example.com", role: "admin"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/users")

    html =
      render_submit(view, "change_role", %{"user_id" => to_string(admin.id), "role" => "member"})

    assert html =~ "Role updated."
    assert Accounts.get_user(admin.id).role == "member"
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
