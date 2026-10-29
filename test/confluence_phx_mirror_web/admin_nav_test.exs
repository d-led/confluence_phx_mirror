defmodule ConfluencePhxMirrorWeb.AdminNavTest do
  @moduledoc """
  The admin sidebar: every page is one link away from every other, and the page
  on screen is the one it marks.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirror.TestConfig

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  @paths ~w(/admin /admin/jobs /admin/sync-log /admin/webhooks /admin/audit
            /admin/trash /admin/spaces /admin/upstream /admin/users /admin/identities
            /admin/groups /admin/permissions /admin/settings)

  setup do
    demo_snapshot!()
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
    TestConfig.put(:admins, ["ops@example.com"])

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
