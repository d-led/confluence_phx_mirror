defmodule ConfluencePhxMirror.Accounts.AdminsTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo

  test "the admin role is the first source" do
    assert Admins.source(user_fixture(%{role: "admin"})) == :role
  end

  test "an e-mail seeded through config administers the mirror" do
    with_env(:admins, ["Ops@Example.com"])
    user = user_fixture(%{email: "ops@example.com"})

    assert Admins.source(user) == :seed
    assert Admins.admin?(user)
  end

  test "membership of an admin group administers the mirror" do
    with_env(:admin_groups, ["confluence-admins"])

    {:ok, _} =
      Mirror.replace_group_members("confluence-admins", [
        %{email: "lead@example.com", display_name: "Lead"}
      ])

    user = user_fixture(%{email: "lead@example.com"})

    assert Admins.source(user) == :group
  end

  test "losing the group in Confluence takes administration away" do
    with_env(:admin_groups, ["confluence-admins"])
    user = user_fixture(%{email: "lead@example.com"})

    {:ok, _} =
      Mirror.replace_group_members("confluence-admins", [%{email: "lead@example.com"}])

    assert Admins.admin?(user)

    {:ok, _} = Mirror.replace_group_members("confluence-admins", [])

    refute Admins.admin?(Accounts.get_user(user.id))
  end

  test "a plain member is not an administrator" do
    refute Admins.admin?(user_fixture(%{email: "reader@example.com", role: "member"}))
    refute Admins.admin?(nil)
  end

  test "groups set through the admin UI are normalised and audited" do
    user = user_fixture(%{email: "team@example.com"})

    assert {:ok, user} =
             Accounts.update_groups(user, [" Product-Team ", "Site-Admins"], {:system, "test"})

    assert user.groups == ["product-team", "site-admins"]
  end

  test "seeded and bootstrap administrators cannot be demoted" do
    with_env(:admins, ["ops@example.com"])

    seeded = user_fixture(%{email: "ops@example.com", role: "admin"})
    bootstrap = user_fixture(%{email: "admin@localhost", role: "admin"})

    assert Admins.protected?(seeded)
    assert Admins.protected?(bootstrap)

    assert {:error, :protected_admin} = Accounts.change_role(seeded, "member", {:system, "test"})

    assert {:error, :protected_admin} =
             Accounts.change_role(bootstrap, "member", {:system, "test"})

    assert Accounts.get_user(seeded.id).role == "admin"
    assert Accounts.get_user(bootstrap.id).role == "admin"
  end

  test "an ordinary administrator can step down" do
    admin = user_fixture(%{email: "lead@example.com", role: "admin"})

    refute Admins.protected?(admin)
    assert {:ok, %{role: "member"}} = Accounts.change_role(admin, "member", {:system, "test"})
  end

  defp with_env(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, key, previous) end)
  end
end
