defmodule ConfluencePhxMirrorWeb.Live.AdminUsersLiveTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User

  defp change_role(view, user, role) do
    render_submit(view, "change_role", %{"user_id" => to_string(user.id), "role" => role})
  end

  test "accounts come from sign-in, not from this screen", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Account provisioning"
    refute html =~ "create-user-form"
  end

  test "protected administrators cannot be demoted", %{conn: conn} do
    admin = Accounts.ensure_admin!()
    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Protected"
    assert {:error, :protected_admin} = Accounts.change_role(admin, "member", {:system, "test"})
  end

  test "an admin changes someone's role", %{conn: conn} do
    reader = user_fixture(%{email: "role.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert change_role(view, reader, "admin") =~ "Role updated."

    assert Accounts.get_user(reader.id).role == "admin"
  end

  test "an admin issues an API token and sees it exactly once", %{conn: conn} do
    reader = user_fixture(%{email: "token.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      view
      |> element("#new-token-#{reader.id}")
      |> render_submit(%{"user_id" => reader.id, "name" => "deck"})

    assert html =~ "New token for token.reader@example.com"
    assert [%{name: "deck"}] = Accounts.list_api_tokens(reader)
  end

  test "a token without a name is refused", %{conn: conn} do
    reader = user_fixture(%{email: "blank.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      view
      |> element("#new-token-#{reader.id}")
      |> render_submit(%{"user_id" => reader.id, "name" => "  "})

    assert html =~ "Could not create token"
    assert Accounts.list_api_tokens(reader) == []
  end

  test "dismissing the new token hides it again", %{conn: conn} do
    reader = user_fixture(%{email: "dismiss.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view
    |> element("#new-token-#{reader.id}")
    |> render_submit(%{"user_id" => reader.id, "name" => "deck"})

    refute render_click(view, "dismiss_token") =~ "New API token"
  end

  test "an admin revokes a token", %{conn: conn} do
    reader = user_fixture(%{email: "revoke.reader@example.com"})
    {:ok, _plain, token} = Accounts.create_api_token(reader, "old", {:system, "test"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "revoke_token", %{
        "user_id" => to_string(reader.id),
        "token_id" => to_string(token.id)
      })

    assert html =~ "Token revoked."
    assert Accounts.list_api_tokens(reader) == []
  end

  test "revoking a token that is already gone says so", %{conn: conn} do
    reader = user_fixture(%{email: "gone.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "revoke_token", %{
        "user_id" => to_string(reader.id),
        "token_id" => "0"
      })

    assert html =~ "Token not found."
  end

  test "an admin grants extra groups by hand", %{conn: conn} do
    reader = user_fixture(%{email: "groups.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "update_groups", %{
        "user_id" => to_string(reader.id),
        "groups" => "incident-responders, on-call"
      })

    assert html =~ "Groups updated."
    assert Accounts.get_user(reader.id).groups == ["incident-responders", "on-call"]
  end

  test "an admin issues a service token and sees it exactly once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      view
      |> element("#create-service-token")
      |> render_submit(%{"name" => "confluence-webhooks", "scope" => "webhook"})

    assert html =~ "Service token created"
    assert html =~ "New token for service: confluence-webhooks"
    assert [%{name: "confluence-webhooks", scope: "webhook"}] = Accounts.list_service_tokens()
  end

  test "an admin revokes a service token", %{conn: conn} do
    {:ok, _plain, token} = Accounts.create_service_token("old", "webhook", {:system, "test"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html = render_submit(view, "revoke_service_token", %{"token_id" => to_string(token.id)})

    assert html =~ "Service token revoked."
    assert Accounts.list_service_tokens() == []
  end

  test "revoking a service token that is already gone says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html = render_submit(view, "revoke_service_token", %{"token_id" => "0"})

    assert html =~ "Service token not found."
  end

  test "a protected administrator stays an administrator even if the event arrives", %{
    conn: conn
  } do
    admin = Accounts.ensure_admin!()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert change_role(view, admin, "member") =~ "Could not update the role."
    assert Accounts.get_user(admin.id).role == "admin"
  end

  describe "disablement" do
    test "an administrator switches an account off here, and the flag shows", %{conn: conn} do
      reader = user_fixture(%{email: "off.reader@example.com"})
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> element("#disable-form-#{reader.id}") |> render_submit()

      assert has_element?(view, "#disabled-here-#{reader.id}")
      assert User.disabled_here?(Accounts.get_user(reader.id))
      refute User.disabled_on_site?(Accounts.get_user(reader.id))
    end

    test "a site disablement is shown apart from ours", %{conn: conn} do
      reader = user_fixture(%{email: "site.off@example.com"})

      assert Accounts.reconcile_site_disabled("557058:site.off", "site.off@example.com", true) ==
               1

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#disabled-on-site-#{reader.id}")
      refute has_element?(view, "#disabled-here-#{reader.id}")
    end

    test "the filter narrows the list as the administrator types", %{conn: conn} do
      user_fixture(%{email: "needle@example.com"})
      user_fixture(%{email: "haystack@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> element("#user-filter") |> render_change(%{"q" => "needle"})

      assert render(view) =~ "needle@example.com"
      refute render(view) =~ "haystack@example.com"

      view |> element("#user-filter") |> render_change(%{"q" => "nothing-matches"})

      assert has_element?(view, "#accounts-empty")
    end
  end
end
