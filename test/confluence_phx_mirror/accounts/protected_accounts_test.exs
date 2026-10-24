defmodule ConfluencePhxMirror.Accounts.ProtectedAccountsTest do
  @moduledoc """
  A seeded administrator, and the bootstrap account, are a deployment's way in.
  The rule is about the row and not about the count of administrators: no event
  may demote, switch off, ban or delete one — whoever sends it.

  Delete was the hole. It asked only "is this the last administrator?", so a
  seeded administrator with a colleague drew an enabled Delete button and the
  server agreed with it: the account went, and the next boot seeded a stranger
  with the same address and none of its history. These are the cases that hold
  that shut, stated once, for every way in that `Admins.protected?/1` names.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts

  describe "an address the deployment seeds" do
    setup do
      seeded(:admins, ["boss@example.com"])
    end

    test "cannot be deleted, even while another administrator exists" do
      boss = user_fixture(%{email: "boss@example.com", role: "admin"})
      _colleague = user_fixture(%{email: "colleague@example.com", role: "admin"})

      refute Accounts.last_admin?(boss)

      assert Accounts.deletion_blocked(boss) == {:error, :protected_admin}
      assert Accounts.delete_user(boss, {:system, "test"}) == {:error, :protected_admin}
      assert Accounts.get_user(boss.id)
    end

    test "the refusal is about the protection, not about being the only one" do
      boss = user_fixture(%{email: "boss@example.com", role: "admin"})

      assert Accounts.last_admin?(boss)
      assert Accounts.deletion_blocked(boss) == {:error, :protected_admin}
    end
  end

  describe "the bootstrap account" do
    setup do
      seeded(:auto_admin_email, "root@localhost")
    end

    test "cannot be deleted either, and the reason is its protection" do
      root = user_fixture(%{email: "root@localhost", role: "admin"})
      _colleague = user_fixture(%{email: "colleague@example.com", role: "admin"})

      refute Accounts.last_admin?(root)

      assert Accounts.deletion_blocked(root) == {:error, :protected_admin}
      assert Accounts.delete_user(root, {:system, "test"}) == {:error, :protected_admin}
      assert Accounts.get_user(root.id)
    end
  end

  test "an administrator the deployment did not seed is still deletable" do
    extra = user_fixture(%{email: "extra@example.com", role: "admin"})
    _colleague = user_fixture(%{email: "colleague@example.com", role: "admin"})

    assert Accounts.deletion_blocked(extra) == nil
    assert {:ok, _} = Accounts.delete_user(extra, {:system, "test"})
    refute Accounts.get_user(extra.id)
  end

  test "the rule a row shows and the rule the event applies are the same function" do
    seeded(:admins, ["boss@example.com"])
    boss = user_fixture(%{email: "boss@example.com", role: "admin"})

    # The screen draws its button from `deletion_blocked/1`; the event calls
    # `delete_user/2`. One answer, or a button promises what the server refuses.
    assert Accounts.deletion_blocked(boss) ==
             Accounts.delete_user(boss, {:system, "test"})
  end

  defp seeded(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)

    on_exit(fn ->
      # A key that was absent has to go back to absent: `put_env(key, nil)`
      # leaves a nil behind, and the defaults the production code relies on are
      # only applied to a missing key.
      if is_nil(previous),
        do: Application.delete_env(:confluence_phx_mirror, key),
        else: Application.put_env(:confluence_phx_mirror, key, previous)
    end)
  end
end
