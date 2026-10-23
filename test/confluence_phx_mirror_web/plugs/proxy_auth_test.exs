defmodule ConfluencePhxMirrorWeb.Plugs.ProxyAuthTest do
  @moduledoc """
  The proxy answers "who is this?", not "should they be here?". An Atlassian
  organisation is usually wider than the site being mirrored, so the mirror
  admits an identity only when it has a reason to: an administrator, or somebody
  the sync has seen on the mirrored site.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.{Accounts, Mirror}

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :proxy_auth)
    previous_members = Application.get_env(:confluence_phx_mirror, :proxy_auth_members_only)
    previous_admin = Application.get_env(:confluence_phx_mirror, :auto_admin)

    Application.put_env(:confluence_phx_mirror, :proxy_auth, true)
    Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, true)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)

    on_exit(fn ->
      Application.put_env(:confluence_phx_mirror, :proxy_auth, previous)
      Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, previous_members)
      Application.put_env(:confluence_phx_mirror, :auto_admin, previous_admin)
    end)

    :ok
  end

  defp visit(email) do
    build_conn()
    |> put_req_header("x-forwarded-email", email)
    |> get(~p"/")
  end

  test "a member of a synced group signs in and gets an account" do
    in_group("jane@example.com", "confluence-users")

    assert html_response(visit("jane@example.com"), 200)
    assert Accounts.get_user_by_email("jane@example.com")
  end

  test "the same identity reuses the account" do
    in_group("jane@example.com", "confluence-users")

    visit("jane@example.com")
    visit("jane@example.com")

    assert [_user] = Accounts.list_users() |> Enum.filter(&(&1.email == "jane@example.com"))
  end

  test "a user named in a space permission is admitted" do
    space = space_fixture()

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "user", subject_key: "bob@example.com"}
      ])

    assert html_response(visit("bob@example.com"), 200)
    assert Accounts.get_user_by_email("bob@example.com")
  end

  test "an identity the mirrored site never mentions is refused, and no account is made" do
    conn = visit("stranger@example.com")

    assert html_response(conn, 403) =~ "not one the mirror was built for"
    refute Accounts.get_user_by_email("stranger@example.com")
  end

  test "a disabled account is refused even though the site knows it" do
    in_group("jane@example.com", "confluence-users")
    {:ok, user} = Accounts.ensure_user("jane@example.com")
    {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

    assert html_response(visit("jane@example.com"), 403)
  end

  test "a seeded administrator signing in through the proxy reaches the admin area", %{conn: conn} do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    conn = put_req_header(conn, "x-forwarded-email", "ops@example.com")

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Sync runs"
  end

  test "members-only can be switched off, so the proxy's word is enough again" do
    Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, false)

    assert html_response(visit("stranger@example.com"), 200)
    assert Accounts.get_user_by_email("stranger@example.com")
  end

  test "the header is ignored when proxy auth is off", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :proxy_auth, false)

    conn = conn |> put_req_header("x-forwarded-email", "jane@example.com") |> get(~p"/")

    assert html_response(conn, 200)
    refute Accounts.get_user_by_email("jane@example.com")
  end

  defp in_group(email, group) do
    {:ok, _} = Mirror.replace_group_members(group, [%{email: email, display_name: "Jane"}])
  end
end
