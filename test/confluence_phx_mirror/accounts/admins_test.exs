defmodule ConfluencePhxMirror.Accounts.AdminsTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Accounts.User
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
    user = user_fixture(%{email: "lead@example.com"}) |> with_groups(["Confluence-Admins"])

    assert Admins.source(user) == :group
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

  defp with_groups(user, groups) do
    {:ok, user} = user |> User.identity_changeset(%{groups: groups}) |> Repo.update()
    user
  end

  defp with_env(key, value) do
    previous = Application.get_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, key, previous) end)
  end
end
