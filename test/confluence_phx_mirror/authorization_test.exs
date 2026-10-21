defmodule ConfluencePhxMirror.AuthorizationTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo

  setup do
    demo_snapshot!()
    :ok
  end

  test "an open space is readable without signing in" do
    space = Mirror.get_space_by_key("ENG")

    assert Authorization.can_read_space?(anonymous(), space)
  end

  test "a page restricted to a group is hidden from readers outside it" do
    page = Mirror.get_page!(1003)

    refute Authorization.can_read_page?(anonymous(), page)
    refute Authorization.can_read_page?(reader("someone@example.com"), page)
    assert Authorization.can_read_page?(reader("insider@example.com", ["confluence-users"]), page)
  end

  test "a space restricted to signed-in users hides itself from anonymous readers" do
    space = Mirror.get_space_by_key("PROD")

    refute Authorization.can_read_space?(anonymous(), space)
    assert Authorization.can_read_space?(reader("reader@example.com"), space)
  end

  test "restricting a page by account id matches the same reader" do
    page = Mirror.get_page!(1002)

    {:ok, _} =
      Mirror.replace_page_restrictions(page, [%{subject_type: "user", subject_key: "acc-42"}])

    refute Authorization.can_read_page?(reader("someone@example.com"), page)

    reader = reader("someone@example.com")

    {:ok, user} =
      reader.user |> User.identity_changeset(%{confluence_account_id: "acc-42"}) |> Repo.update()

    assert Authorization.can_read_page?(Scope.for_user(user), page)
  end

  test "mirror administrators see everything" do
    admin = user_fixture(%{email: "admin@confluence-mirror.test", role: "admin"})
    scope = Scope.for_user(admin)

    assert Authorization.can_read_page?(scope, Mirror.get_page!(1003))
    assert Authorization.can_read_space?(scope, Mirror.get_space_by_key("PROD"))
  end

  test "the sync stores the permissions it read" do
    assert Mirror.page_restrictions(1003) == [
             %{subject_type: "group", subject_key: "confluence-users"}
           ]

    refute Mirror.space_permissions(Mirror.get_space_by_key("PROD").id) == []
    assert Mirror.space_permissions(Mirror.get_space_by_key("ENG").id) == []
  end

  test "a reader who is in the group according to Confluence may read the page" do
    page = Mirror.get_page!(1003)
    outsider = "late-joiner@demo.atlassian.net"

    refute Authorization.can_read_page?(reader(outsider), page)

    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [
        %{email: outsider, display_name: "Late Joiner"}
      ])

    assert Authorization.can_read_page?(reader(outsider), page)
  end

  defp anonymous, do: Scope.for_user(nil)

  defp reader(email, groups \\ []) do
    user = user_fixture(%{email: email})

    {:ok, user} =
      user
      |> User.identity_changeset(%{groups: groups})
      |> Repo.update()

    Scope.for_user(user)
  end
end
