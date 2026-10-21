defmodule ConfluencePhxMirrorWeb.Live.AdminUsersLiveTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts

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

    assert html =~ "New API token for token.reader@example.com"
    assert [%{name: "deck"}] = Accounts.list_api_tokens(reader)
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
end
