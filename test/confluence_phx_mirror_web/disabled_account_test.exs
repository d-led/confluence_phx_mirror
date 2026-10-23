defmodule ConfluencePhxMirrorWeb.DisabledAccountTest do
  @moduledoc """
  A disabled account is nobody, whichever door it comes through: the session it
  already holds, a bearer token it was issued, or a magic link it requested
  before the flag was set.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  defp disabled_user(email) do
    user = user_fixture(%{email: email, role: "admin"})
    {:ok, user} = Accounts.set_disabled(user, true, {:system, "test"})
    user
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  test "the session it already holds no longer signs it in", %{conn: conn} do
    user = disabled_user("gone@example.com")

    assert {:error, {:redirect, %{to: "/session"}}} =
             signed_in(conn, user) |> live(~p"/admin")
  end

  test "its bearer token is refused with 403, not a silent empty answer", %{conn: conn} do
    user = user_fixture(%{email: "token.gone@example.com"})
    {:ok, plain, _token} = Accounts.create_api_token(user, "ci", {:system, "test"})

    assert %{"results" => _} =
             conn
             |> put_req_header("authorization", "Bearer " <> plain)
             |> get(~p"/api/v1/spaces")
             |> json_response(200)

    {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> plain)
      |> get(~p"/api/v1/spaces")
      |> json_response(403)

    assert body["error"] == "account_disabled"
  end

  test "asking for a sign-in link says the account is disabled", %{conn: conn} do
    user = user_fixture(%{email: "link.gone@example.com"})
    {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

    conn = post(conn, ~p"/session", %{"user" => %{"email" => "link.gone@example.com"}})

    assert redirected_to(conn) == ~p"/session"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
  end

  test "re-enabling gives access back" do
    user = user_fixture(%{email: "back.again@example.com"})
    {:ok, plain, _token} = Accounts.create_api_token(user, "ci", {:system, "test"})

    {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})
    assert {:error, :account_disabled} = Accounts.authenticate_api_token(plain)

    {:ok, _} = Accounts.set_disabled(Accounts.get_user(user.id), false, {:system, "test"})
    assert {:ok, %{id: id}} = Accounts.authenticate_api_token(plain)
    assert id == user.id
  end
end
