defmodule ConfluencePhxMirror.Accounts.ModerationTest do
  @moduledoc """
  Three ways an account can be kept out, and they are not the same thing:

    * switched off here — an administrator's decision, reversible here;
    * switched off on the site — the site's decision, which the mirror follows
      unless this deployment was told to admit such readers;
    * gone from the site, or banned here — never relaxed, and in the banned case
      the account cannot even be deleted while the ban stands.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User

  test "a banned reader is refused with no other flag set" do
    user = user_fixture(%{email: "banned@example.com"})

    assert {:ok, banned} = Accounts.ban(user, {:system, "test"})

    assert User.banned?(banned)
    assert User.disabled?(Accounts.get_user(user.id))
    assert {:error, :disabled} = Accounts.request_login("banned@example.com")
  end

  test "a ban outlives a sync that reports the account active again" do
    user = user_fixture(%{email: "banned@example.com"})
    {:ok, _} = Accounts.ban(user, {:system, "test"})

    Accounts.reconcile_site_status("557058:banned", "banned@example.com", :active)

    assert User.banned?(Accounts.get_user(user.id))
    assert User.disabled?(Accounts.get_user(user.id))
  end

  test "a ban is lifted only by an administrator" do
    user = user_fixture(%{email: "banned@example.com"})
    {:ok, banned} = Accounts.ban(user, {:system, "test"})

    assert {:ok, unbanned} = Accounts.unban(banned, {:system, "test"})

    refute User.banned?(unbanned)
    refute User.disabled?(Accounts.get_user(user.id))
  end

  test "a banned account cannot be deleted, and nothing else cannot" do
    banned = user_fixture(%{email: "banned@example.com"})
    {:ok, _} = Accounts.ban(banned, {:system, "test"})

    assert {:error, :banned} =
             Accounts.delete_user(Accounts.get_user(banned.id), {:system, "test"})

    assert Accounts.get_user(banned.id)

    plain = user_fixture(%{email: "plain@example.com"})
    assert {:ok, _} = Accounts.delete_user(plain, {:system, "test"})
    refute Accounts.get_user(plain.id)
  end

  test "deleting an account takes its tokens with it" do
    user = user_fixture(%{email: "tokenful@example.com"})
    {:ok, plain, _token} = Accounts.create_api_token(user, "ci", {:system, "test"})

    assert {:ok, _} = Accounts.delete_user(user, {:system, "test"})

    assert {:error, :invalid_token} = Accounts.authenticate_api_token(plain)
  end

  test "the last administrator cannot be deleted" do
    admin = user_fixture(%{email: "only@example.com", role: "admin"})

    assert {:error, :last_admin} = Accounts.delete_user(admin, {:system, "test"})
    assert Accounts.get_user(admin.id)
  end

  test "the last administrator cannot be banned either — a ban outlives every sync" do
    admin = user_fixture(%{email: "only@example.com", role: "admin"})

    assert {:error, :last_admin} = Accounts.ban(admin, {:system, "test"})
    refute User.banned?(Accounts.get_user(admin.id))
    assert User.disabled?(Accounts.get_user(admin.id)) == false
  end

  test "an administrator with a colleague can be banned" do
    admin = user_fixture(%{email: "one-of-two@example.com", role: "admin"})
    user_fixture(%{email: "the-other@example.com", role: "admin"})

    assert {:ok, banned} = Accounts.ban(admin, {:system, "test"})
    assert User.banned?(banned)
  end

  test "a reader the site switched off is refused, because the site decides" do
    user = user_fixture(%{email: "off@example.com"})

    assert Accounts.reconcile_site_status("557058:off", "off@example.com", :disabled) == 1

    assert User.disabled_on_site?(Accounts.get_user(user.id))
    assert User.disabled?(Accounts.get_user(user.id))
  end

  test "a deployment may admit the readers the site switched off, but not the ones it lost" do
    with_env(:allow_site_disabled_readers, true)
    switched_off = user_fixture(%{email: "off@example.com"})
    gone = user_fixture(%{email: "gone@example.com"})

    Accounts.reconcile_site_status("557058:off", "off@example.com", :disabled)
    Accounts.reconcile_site_status("557058:gone", "gone@example.com", :deleted)

    refute User.disabled?(Accounts.get_user(switched_off.id))
    assert User.disabled?(Accounts.get_user(gone.id))
  end

  test "an account the site no longer has is marked deleted and cannot be used" do
    user = account_with_id("gone@example.com", "557058:gone")

    assert Accounts.reconcile_site_status("557058:gone", nil, :deleted) == 1

    reloaded = Accounts.get_user(user.id)
    assert User.deleted_on_site?(reloaded)
    refute User.disabled_on_site?(reloaded)
    assert User.disabled?(reloaded)
  end

  # A deleted account comes back without an e-mail, so the account id is the
  # only thing left to match it on.
  defp account_with_id(email, account_id) do
    user = user_fixture(%{email: email})

    {:ok, user} =
      user
      |> User.identity_changeset(%{confluence_account_id: account_id})
      |> ConfluencePhxMirror.Repo.update()

    user
  end

  defp with_env(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, key, previous) end)
  end
end
