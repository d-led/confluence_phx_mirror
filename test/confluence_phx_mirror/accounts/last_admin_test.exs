defmodule ConfluencePhxMirror.Accounts.LastAdminTest do
  @moduledoc """
  The mirror has to keep one administrator. Seeded and bootstrap accounts
  cannot be demoted; these are the cases of whoever is left, which is the same
  rule seen from the other end.
  """
  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.TestConfig

  test "the one administrator cannot step down" do
    admin = user_fixture(%{email: "only@example.com", role: "admin"})

    assert Accounts.last_admin?(admin)
    assert {:error, :last_admin} = Accounts.change_role(admin, "member", {:system, "test"})
    assert Accounts.get_user(admin.id).role == "admin"
  end

  test "the one administrator cannot switch itself off" do
    admin = user_fixture(%{email: "only@example.com", role: "admin"})

    assert {:error, :last_admin} = Accounts.set_disabled(admin, true, {:system, "test"})
    refute User.disabled?(Accounts.get_user(admin.id))
  end

  test "stepping down is allowed once another administrator exists" do
    admin = user_fixture(%{email: "only@example.com", role: "admin"})
    user_fixture(%{email: "backup@example.com", role: "admin"})

    refute Accounts.last_admin?(Accounts.get_user(admin.id))
    assert {:ok, %{role: "member"}} = Accounts.change_role(admin, "member", {:system, "test"})
  end

  test "an administrator who is switched off is not a way in" do
    admin = user_fixture(%{email: "only@example.com", role: "admin"})
    spare = user_fixture(%{email: "spare@example.com", role: "admin"})
    {:ok, _} = Accounts.set_disabled(spare, true, {:system, "test"})

    assert {:error, :last_admin} = Accounts.change_role(admin, "member", {:system, "test"})
  end

  test "a member of an admin group is a way in, even with no account here" do
    TestConfig.put(:admin_groups, ["confluence-admins"])
    admin = user_fixture(%{email: "only@example.com", role: "admin"})

    {:ok, _} = Mirror.replace_group_members("confluence-admins", [%{email: "boss@example.com"}])

    refute Accounts.last_admin?(admin)
    assert {:ok, %{role: "member"}} = Accounts.change_role(admin, "member", {:system, "test"})
  end

  test "a seeded address that has never signed in is a way in" do
    TestConfig.put(:admins, ["boss@example.com"])
    admin = user_fixture(%{email: "only@example.com", role: "admin"})

    refute Accounts.last_admin?(admin)
    assert {:ok, %{role: "member"}} = Accounts.change_role(admin, "member", {:system, "test"})
  end
end
