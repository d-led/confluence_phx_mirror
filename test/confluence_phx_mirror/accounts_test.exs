defmodule ConfluencePhxMirror.AccountsTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{ApiToken, LoginToken, User}
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

      assert token.token_prefix == String.slice(plain, 0, 12)

      stored = Repo.get!(ApiToken, token.id).token_hash
      refute stored =~ plain
      assert stored =~ ~r/\A\$argon2id\$/

      assert {:ok, %{id: id}} = Accounts.authenticate_api_token(plain)
      assert id == user.id
      assert {:error, :invalid_token} = Accounts.authenticate_api_token("nope")

      assert :ok = Accounts.revoke_api_token(user, token.id, {:system, "test"})
      assert {:error, :invalid_token} = Accounts.authenticate_api_token(plain)
    end

    test "a digest written before the algorithm changed is rewritten on first use" do
      user = user_fixture()
      plain = "legacy-token-value"

      legacy = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          user_id: user.id,
          name: "issued before the change",
          token_hash: legacy,
          token_prefix: String.slice(plain, 0, 12)
        })
        |> Repo.insert()

      assert {:ok, %{id: id}} = Accounts.authenticate_api_token(plain)
      assert id == user.id

      assert Repo.get!(ApiToken, token.id).token_hash =~ ~r/\A\$argon2id\$/
      assert {:ok, %{id: ^id}} = Accounts.authenticate_api_token(plain)
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

  describe "disablement" do
    test "an administrator switches an account off here, and it is audited" do
      user = user_fixture(%{email: "off@example.com"})

      assert {:ok, disabled} = Accounts.set_disabled(user, true, {:system, "test"})
      assert User.disabled_here?(disabled)
      refute User.disabled_on_site?(disabled)
      assert User.disabled?(disabled)

      assert Repo.exists?(
               from e in Event,
                 where: e.action == "user.disabled" and e.entity_id == ^to_string(user.id)
             )
    end

    test "switching it back on clears the flag and is audited too" do
      user = user_fixture(%{email: "back@example.com"})
      {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

      assert {:ok, enabled} =
               Accounts.set_disabled(Accounts.get_user(user.id), false, {:system, "test"})

      refute User.disabled?(enabled)
      assert Repo.exists?(from e in Event, where: e.action == "user.enabled")
    end

    test "a seeded administrator cannot be switched off, or nobody could get back in" do
      previous = Application.get_env(:confluence_phx_mirror, :admins)
      Application.put_env(:confluence_phx_mirror, :admins, ["keeper@example.com"])
      on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

      keeper = user_fixture(%{email: "keeper@example.com", role: "admin"})

      assert {:error, :protected_admin} = Accounts.set_disabled(keeper, true, {:system, "test"})
      refute User.disabled?(Accounts.get_user(keeper.id))
    end

    test "the site's flag and ours are independent, and either one blocks the token" do
      user = user_fixture(%{email: "both@example.com"})
      {:ok, plain, _token} = Accounts.create_api_token(user, "ci", {:system, "test"})

      assert Accounts.reconcile_site_disabled("557058:both", "both@example.com", true) == 1

      reloaded = Accounts.get_user(user.id)
      assert User.disabled_on_site?(reloaded)
      refute User.disabled_here?(reloaded)
      assert {:error, :account_disabled} = Accounts.authenticate_api_token(plain)

      assert Accounts.reconcile_site_disabled("557058:both", "both@example.com", false) == 1
      assert {:ok, %{id: id}} = Accounts.authenticate_api_token(plain)
      assert id == user.id
    end

    test "a site transition is written once, not once per sync" do
      user = user_fixture(%{email: "quiet@example.com"})

      assert Accounts.reconcile_site_disabled("557058:quiet", "quiet@example.com", true) == 1
      assert Accounts.reconcile_site_disabled("557058:quiet", "quiet@example.com", true) == 0

      assert Repo.exists?(from e in Event, where: e.action == "user.site_disabled")
      assert User.disabled_on_site?(Accounts.get_user(user.id))
    end

    test "a disabled account cannot request or consume a magic link" do
      user = user_fixture(%{email: "nolink@example.com"})

      assert {:ok, :sent} = Accounts.request_login("nolink@example.com")

      assert_email_sent(fn email ->
        [_, plain] = Regex.run(~r{/session/([A-Za-z0-9_-]+)}, email.text_body)
        send(self(), {:token, plain})
        true
      end)

      assert_received {:token, plain}

      {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

      assert {:error, :disabled} = Accounts.request_login("nolink@example.com")
      assert {:error, :disabled} = Accounts.consume_login(plain)
    end

    test "the account list can be narrowed by address or name" do
      user_fixture(%{email: "find.me@example.com", display_name: "Findable Person"})
      user_fixture(%{email: "other@example.com", display_name: "Someone Else"})

      assert Enum.map(Accounts.list_users("findable"), & &1.email) == ["find.me@example.com"]
      assert Enum.map(Accounts.list_users("find.me"), & &1.email) == ["find.me@example.com"]
      assert length(Accounts.list_users("")) == length(Accounts.list_users())
    end
  end
end
