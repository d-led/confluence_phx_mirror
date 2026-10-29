defmodule ConfluencePhxMirror.Mirror.GroupCatalogueTest do
  @moduledoc """
  What an administrator auditing access is shown about a group.

  A group is one line in the mirror — `group_members` rows the sync wrote — and
  what it *decides* is spread over the tables the access rules read. The
  catalogue joins the two: how many members, how old the answer is, whether the
  group decides who reads, and what it decides.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.TestConfig

  setup do
    space = space_fixture(%{key: "AUDIT", name: "Audit & Review"})

    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [
        %{email: "jane@example.com", display_name: "Jane Doe"},
        %{email: "sam@example.com", display_name: "Sam Rivera"}
      ])

    {:ok, _} = Mirror.replace_group_members("product-team", [%{email: "jane@example.com"}])

    %{space: space}
  end

  test "a group the sync read is listed with its size and when it was read" do
    [users, team] = Mirror.group_catalogue()

    assert users.name == "confluence-users"
    assert users.key == "confluence-users"
    assert users.members == 2
    assert %DateTime{} = users.read_at

    assert team.name == "product-team"
    assert team.members == 1
  end

  test "a group whose membership decides who reads says so", %{space: space} do
    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "group", subject_key: "confluence-users"}
      ])

    assert [users, team] = Mirror.group_catalogue()

    assert users.decides_access?
    refute team.decides_access?
  end

  test "a group the deployment administers with says so" do
    TestConfig.put(:admin_groups, ["Product-Team"])

    assert [users, team] = Mirror.group_catalogue()

    refute users.admin?
    assert team.admin?
  end

  test "the list is searched by name, and counted" do
    assert ["product-team"] = Enum.map(Mirror.group_catalogue(query: "PRODUCT"), & &1.key)
    assert Mirror.count_groups(query: "product") == 1
    assert Mirror.count_groups() == 2
  end

  test "one group is asked for by a name Confluence spells in any case" do
    assert %{key: "confluence-users", members: 2} = Mirror.group("Confluence-Users")
    assert Mirror.group("nowhere") == nil
  end

  describe "what a group grants" do
    setup %{space: space} do
      page = page_fixture(space, %{confluence_id: 4242, title: "Salaries"})

      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "group", subject_key: "confluence-users"}
        ])

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "confluence-users"}
        ])

      %{page: page}
    end

    test "the spaces it may read, and the pages restricted to it" do
      %{spaces: spaces, pages: pages} = Mirror.group_access("Confluence-Users")

      assert [%{key: "AUDIT", operation: "read", source: :site}] = spaces

      assert [%{space: "AUDIT", confluence_id: 4242, title: "Salaries", source: :site}] =
               pages
    end

    test "a group nothing names grants nothing" do
      assert %{spaces: [], pages: []} = Mirror.group_access("product-team")
    end

    test "a grant an administrator took away here is still listed, and says so", %{space: space} do
      admin = user_fixture(%{email: "ops@example.com", role: "admin"})

      {:ok, _} = Mirror.remove_space_reader(space, "group", "confluence-users", {:user, admin})

      assert [%{key: "AUDIT", source: :revoked_here}] =
               Mirror.group_access("confluence-users").spaces
    end
  end
end
