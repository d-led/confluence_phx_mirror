defmodule ConfluencePhxMirror.AccountsTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{ApiToken, LoginToken}
  alias ConfluencePhxMirror.Audit.Event

  describe "auto admin" do
    test "creates the configured administrator once" do
      admin = Accounts.ensure_admin!()
      assert admin.role == "admin"
      assert Accounts.ensure_admin!().id == admin.id
      assert Repo.exists?(from e in Event, where: e.action == "user.created")
    end
  end

  describe "magic links" do
    test "send a single-use link and sign the user in" do
      user = user_fixture(%{email: "alice@example.com"})

      assert {:ok, :sent} = Accounts.request_login("Alice@Example.com")

      assert_email_sent(fn email ->
        assert email.subject == "[Mirror] Sign in"
        [_, token] = Regex.run(~r{/session/([A-Za-z0-9_-]+)}, email.text_body)
        send(self(), {:token, token})
        true
      end)

      assert_received {:token, token}
      assert {:ok, signed_in} = Accounts.consume_login(token)
      assert signed_in.id == user.id
      assert signed_in.last_sign_in_at

      assert {:error, :invalid} = Accounts.consume_login(token)
    end

    test "expired tokens are rejected" do
      user = user_fixture()
      plain = "expired-token"

      %LoginToken{}
      |> LoginToken.changeset(%{
        user_id: user.id,
        token_hash: :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower),
        expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
      })
      |> Repo.insert!()

      assert {:error, :expired} = Accounts.consume_login(plain)
    end

    test "unknown addresses do not get an account when self sign-up is off" do
      original = Application.get_env(:confluence_phx_mirror, :self_signup)
      Application.put_env(:confluence_phx_mirror, :self_signup, false)
      on_exit(fn -> Application.put_env(:confluence_phx_mirror, :self_signup, original) end)

      assert {:error, :unknown_email} = Accounts.request_login("nobody@example.com")
      refute Accounts.get_user_by_email("nobody@example.com")
    end
  end

  describe "api tokens" do
    test "creates a token that authenticates its user and can be revoked" do
      user = user_fixture()
      {:ok, plain, token} = Accounts.create_api_token(user, "CI", {:system, "test"})

      assert token.token_prefix == String.slice(plain, 0, 8)
      refute Repo.get!(ApiToken, token.id).token_hash =~ plain
      assert {:ok, %{id: id}} = Accounts.authenticate_api_token(plain)
      assert id == user.id
      assert {:error, :invalid_token} = Accounts.authenticate_api_token("nope")

      assert :ok = Accounts.revoke_api_token(user, token.id, {:system, "test"})
      assert {:error, :invalid_token} = Accounts.authenticate_api_token(plain)
    end

    test "basic auth accepts email and token" do
      user = user_fixture(%{email: "basic@example.com"})
      {:ok, plain, _token} = Accounts.create_api_token(user, "basic", {:system, "test"})

      assert {:ok, %{id: id}} = Accounts.authenticate_basic("basic@example.com", plain)
      assert id == user.id
      assert {:error, :invalid_token} = Accounts.authenticate_basic("someone@example.com", plain)
    end

    test "expired tokens are rejected" do
      user = user_fixture()
      {:ok, plain, token} = Accounts.create_api_token(user, "old", {:system, "test"})

      token
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :expired_token} = Accounts.authenticate_api_token(plain)
    end
  end
end
