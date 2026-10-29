defmodule ConfluencePhxMirrorWeb.ApiUserTest do
  @moduledoc """
  `POST /api/v1/users`: an account made before its person arrives.

  The same door the users screen has, for scripts — an address, a role, and a
  row that exists before anybody signs in. It is an administrator's decision:
  creating an account writes the row admission is judged by.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.TestConfig

  setup do
    # A token is the API's credential; nobody is an administrator by default.
    TestConfig.put(:auto_admin, false)
    :ok
  end

  test "an administrator creates an account with a role", %{conn: conn} do
    conn =
      conn
      |> api_admin_token()
      |> post(~p"/api/v1/users", %{"email" => "Bert.Lindner@Example.com", "role" => "admin"})

    assert %{
             "id" => id,
             "email" => "bert.lindner@example.com",
             "role" => "admin",
             "welcome" => "sent"
           } = json_response(conn, 201)

    assert_email_sent(fn email -> elem(hd(email.to), 1) == "bert.lindner@example.com" end)

    assert Accounts.get_user(id).email == "bert.lindner@example.com"
  end

  test "the account is a member unless an administrator says otherwise", %{conn: conn} do
    conn =
      conn
      |> api_admin_token()
      |> post(~p"/api/v1/users", %{"email" => "member@example.com"})

    assert %{"role" => "member"} = json_response(conn, 201)
  end

  test "it exists before anybody signs in, and no sync claims it", %{conn: conn} do
    conn =
      conn
      |> api_admin_token()
      |> post(~p"/api/v1/users", %{"email" => "waiting@example.com"})

    assert %{"id" => id} = json_response(conn, 201)

    user = Accounts.get_user(id)
    assert user.last_sign_in_at == nil
    refute ConfluencePhxMirror.Accounts.User.provisioned?(user)
  end

  test "an address that is already somebody's is refused", %{conn: conn} do
    user_fixture(%{email: "taken@example.com"})

    conn =
      conn
      |> api_admin_token()
      |> post(~p"/api/v1/users", %{"email" => "taken@example.com"})

    assert %{"error" => %{"code" => "invalid_user", "details" => %{"email" => _}}} =
             json_response(conn, 422)
  end

  test "a member's token may not create an account", %{conn: conn} do
    conn =
      conn
      |> api_member_token()
      |> post(~p"/api/v1/users", %{"email" => "sneaky@example.com"})

    assert %{"error" => %{"code" => "not_authorized"}} = json_response(conn, 403)
    refute Accounts.get_user_by_email("sneaky@example.com")
  end

  test "an account with no address is refused", %{conn: conn} do
    conn = conn |> api_admin_token() |> post(~p"/api/v1/users", %{})

    assert %{"error" => %{"code" => "invalid_user"}} = json_response(conn, 422)
  end

  defp api_admin_token(conn), do: api_token(conn, user_fixture(%{role: "admin"}))

  defp api_member_token(conn), do: api_token(conn, user_fixture(%{role: "member"}))

  defp api_token(conn, user) do
    {:ok, token, _row} = Accounts.create_api_token(user, "test", {:user, user})

    put_req_header(conn, "authorization", "Bearer " <> token)
  end
end
