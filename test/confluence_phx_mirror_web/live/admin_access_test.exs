defmodule ConfluencePhxMirrorWeb.AdminAccessTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror

  setup do
    demo_snapshot!()
    # Readers are anonymous unless a test signs them in.
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
    assert html =~ "Sync runs"
  end

  test "a member of the admin group opens the dashboard", %{conn: conn} do
    with_env(:admin_groups, ["confluence-admins"])

    {:ok, _} =
      Mirror.replace_group_members("confluence-admins", [
        %{email: "lead@example.com", display_name: "Lead"}
      ])

    user = user_fixture(%{email: "lead@example.com"})

    assert {:ok, _view, html} = live(sign_in(conn, user), ~p"/admin")
    assert html =~ "Sync runs"
  end

  test "a seeded administrator may sign in even with self sign-up closed" do
    with_env(:admins, ["new-ops@example.com"])
    with_env(:self_signup, false)

    assert {:ok, :sent} = Accounts.request_login("new-ops@example.com")
    assert Accounts.get_user_by_email("new-ops@example.com")
  end

  describe "the BEAM dashboard" do
    # Every page LiveDashboard serves, not just the way in: it has one LiveView
    # for all of them, and a hook that only guarded the index would leave the
    # processes and ETS pages open to whoever guessed the path.
    @dashboard_pages ~w(home processes ports sockets ets applications)

    test "an anonymous reader is sent to sign in, on every page", %{conn: conn} do
      for path <- ["/admin/runtime" | Enum.map(@dashboard_pages, &"/admin/runtime/#{&1}")] do
        assert {:error, {:redirect, %{to: "/session"}}} = live(conn, path),
               "expected #{path} to require signing in"
      end
    end

    test "a member is sent back home, on every page", %{conn: conn} do
      conn = sign_in(conn, user_fixture(%{email: "member@example.com"}))

      for path <- ["/admin/runtime" | Enum.map(@dashboard_pages, &"/admin/runtime/#{&1}")] do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, path),
               "expected #{path} to refuse a plain member"
      end
    end

    test "a member cannot reach a page through a node name either", %{conn: conn} do
      conn = sign_in(conn, user_fixture(%{email: "member@example.com"}))

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/admin/runtime/#{node()}/home")
    end

    test "an administrator reads the mirror's own metrics", %{conn: conn} do
      with_env(:admins, ["ops@example.com"])
      conn = sign_in(conn, user_fixture(%{email: "ops@example.com", role: "member"}))

      # The dashboard groups metrics by the first segment of their name, and
      # sends `/metrics` to the first group; `confluence_mirror` is ours.
      {:ok, _view, html} =
        live(conn, ~p"/admin/runtime/metrics?nav=confluence_mirror")

      assert html =~ "Pages the mirror holds"
    end

    test "an administrator keeps every page", %{conn: conn} do
      with_env(:admins, ["ops@example.com"])
      conn = sign_in(conn, user_fixture(%{email: "ops@example.com", role: "member"}))

      for page <- @dashboard_pages do
        assert {:ok, _view, _html} = live(conn, "/admin/runtime/#{page}"),
               "expected an administrator to open #{page}"
      end
    end
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp with_env(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, key, previous) end)
  end
end
