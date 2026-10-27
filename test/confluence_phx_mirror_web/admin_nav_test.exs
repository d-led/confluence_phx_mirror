defmodule ConfluencePhxMirrorWeb.AdminNavTest do
  @moduledoc """
  The admin sidebar: every page is one link away from every other, and the page
  on screen is the one it marks.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  @paths ~w(/admin /admin/jobs /admin/sync-log /admin/webhooks /admin/audit
            /admin/trash /admin/upstream /admin/users /admin/identities
            /admin/permissions /admin/settings)

  setup do
    demo_snapshot!()
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "every admin page is one link away", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    for path <- @paths do
      assert has_element?(view, ~s(nav[aria-label="Administration"] a[href="#{path}"])),
             "the sidebar does not link #{path}"
    end
  end

  test "the sidebar marks the page it is showing", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/users")

    assert has_element?(
             view,
             ~s(nav[aria-label="Administration"] a[aria-current="page"][href="/admin/users"])
           )

    refute has_element?(
             view,
             ~s(nav[aria-label="Administration"] a[aria-current="page"][href="/admin/settings"])
           )
  end

  defp admin_user do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
