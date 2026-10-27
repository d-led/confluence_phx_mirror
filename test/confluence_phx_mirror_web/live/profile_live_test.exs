defmodule ConfluencePhxMirrorWeb.Live.ProfileLiveTest do
  @moduledoc """
  A reader's own account, and the only place a personal API token is minted.

  The rule this file holds: a token belongs to the reader who created it. It is
  created here, it authenticates the API as that reader, and nobody else — an
  administrator included — can create one for somebody, which is why the admin
  screen has no such form and this page has no user field.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror

  setup do
    # Readers are anonymous unless a test signs them in; administrators bypass
    # every permission check, and the suite assumes one by default.
    :ok
  end

  test "a reader's own account is the page's first tab", %{conn: conn} do
    reader = user_fixture(%{email: "profile.reader@example.com"})

    {:ok, _view, html} = live_as(conn, reader, ~p"/profile")

    assert html =~ "profile.reader@example.com"
    assert html =~ "Profile"
    assert html =~ "API tokens"
  end

  test "the tokens tab is linkable on its own", %{conn: conn} do
    reader = user_fixture(%{email: "tab.reader@example.com"})

    {:ok, _view, html} = live_as(conn, reader, ~p"/profile?tab=tokens")

    assert html =~ "Your API tokens"
    assert html =~ "No tokens yet."
  end

  test "a reader creates a token and it authenticates the API as that reader", %{conn: conn} do
    reader = user_fixture(%{email: "mint.reader@example.com"})
    {:ok, view, _html} = live_as(conn, reader, ~p"/profile?tab=tokens")

    html = view |> element("#new-token-form") |> render_submit(%{"name" => "my-laptop-cli"})

    assert html =~ "Your new token “my-laptop-cli”"
    [%{name: "my-laptop-cli"}] = Accounts.list_api_tokens(reader)

    plain = shown_token(html)
    assert {:ok, %{id: id}} = Accounts.authenticate_api_token(plain)
    assert id == reader.id
  end

  test "the token belongs to its creator, not to whoever else has an account", %{conn: conn} do
    reader = user_fixture(%{email: "mine.reader@example.com"})
    other = user_fixture(%{email: "theirs.reader@example.com"})

    {:ok, view, _html} = live_as(conn, reader, ~p"/profile?tab=tokens")
    view |> element("#new-token-form") |> render_submit(%{"name" => "mine"})

    assert [%{name: "mine"}] = Accounts.list_api_tokens(reader)
    assert Accounts.list_api_tokens(other) == []
  end

  test "a reader revokes their own token and it stops working", %{conn: conn} do
    reader = user_fixture(%{email: "revoke.reader@example.com"})
    {:ok, plain, token} = Accounts.create_api_token(reader, "old", {:system, "test"})
    {:ok, view, _html} = live_as(conn, reader, ~p"/profile?tab=tokens")

    html = view |> element("#revoke-token-form-#{token.id}") |> render_submit()

    assert html =~ "Token revoked."
    assert Accounts.list_api_tokens(reader) == []
    assert {:error, :invalid_token} = Accounts.authenticate_api_token(plain)
  end

  test "one reader cannot revoke another's token, even by naming its id", %{conn: conn} do
    reader = user_fixture(%{email: "snoop.reader@example.com"})
    other = user_fixture(%{email: "owner.reader@example.com"})
    {:ok, _plain, token} = Accounts.create_api_token(other, "theirs", {:system, "test"})

    {:ok, view, _html} = live_as(conn, reader, ~p"/profile?tab=tokens")

    html = render_submit(view, "revoke_token", %{"token_id" => to_string(token.id)})

    assert html =~ "That token is gone already."
    assert [%{name: "theirs"}] = Accounts.list_api_tokens(other)
  end

  test "a token without a name is refused", %{conn: conn} do
    reader = user_fixture(%{email: "blank.reader@example.com"})
    {:ok, view, _html} = live_as(conn, reader, ~p"/profile?tab=tokens")

    html = render_submit(view, "create_token", %{"name" => "  "})

    assert html =~ "Give the token a name first."
    assert Accounts.list_api_tokens(reader) == []
  end

  test "the groups a reader is in say where they come from", %{conn: conn} do
    reader = user_fixture(%{email: "groups.reader@example.com"})
    {:ok, reader} = Accounts.update_groups(reader, ["on-call"], {:system, "test"})

    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [%{email: "groups.reader@example.com"}])

    {:ok, _view, html} = live_as(conn, reader, ~p"/profile")

    assert html =~ "on-call"
    assert html =~ "confluence-users"
    assert html =~ "Granted on this mirror"
  end

  test "an anonymous visitor is sent to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/session"}}} = live(conn, ~p"/profile")
  end

  defp live_as(conn, user, path) do
    live(init_test_session(conn, %{user_id: user.id}), path)
  end

  # The secret is shown once, inside the success panel; the assertion above says
  # where, so a test can read exactly what the reader would copy.
  defp shown_token(html) do
    [_, token] =
      Regex.run(~r/class="mt-2 block select-all break-all[^"]*"[^>]*>\s*([^\s<]+)/, html)

    token
  end
end
