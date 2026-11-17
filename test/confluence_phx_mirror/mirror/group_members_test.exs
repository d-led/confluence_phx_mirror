defmodule ConfluencePhxMirror.Mirror.GroupMembersTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror

  setup do
    demo_snapshot!()
    :ok
  end

  test "the sync mirrors membership of the groups the content depends on" do
    assert Enum.sort(Enum.map(Mirror.group_members("confluence-users"), & &1.email)) == [
             "dana.whitfield@demo.atlassian.net",
             "jane.doe@demo.atlassian.net",
             "priya.nair@demo.atlassian.net",
             "sam.rivera@demo.atlassian.net"
           ]
  end

  test "the sync mirrors membership of the groups that grant administration" do
    assert [_member | _] = Mirror.group_members("confluence-admins")
  end

  test "group names are matched without regard to case" do
    assert Mirror.member_of_group?(["jane.doe@demo.atlassian.net"], "Confluence-Users")
  end

  # The screens that offer groups show a window, and the permissions dialog asks
  # again on every keystroke — so the matching and the bound belong to the
  # database rather than to a LiveView process holding every name in memory.
  test "the group names can be narrowed by a term and bounded by a window" do
    names = Mirror.synced_group_names()

    assert names == Enum.sort(names)

    matching = Mirror.synced_group_names(query: "admins")
    assert matching != []
    assert Enum.all?(matching, &String.contains?(String.downcase(&1), "admins"))
    assert Mirror.synced_group_names(query: "ADMINS") == matching
    assert Mirror.synced_group_names(query: "admins", limit: 1) == Enum.take(matching, 1)

    assert length(Mirror.synced_group_names(limit: 1)) == 1
    assert Mirror.synced_group_names(query: "nothing-is-called-this") == []
  end

  test "a member is recognised by account id when the site hides e-mails" do
    {:ok, _} =
      Mirror.replace_group_members("product-team", [
        %{account_id: "557058:sam.rivera", display_name: "Sam Rivera"}
      ])

    assert Mirror.member_of_group?(["557058:sam.rivera"], "product-team")
  end

  test "a member who left the group is no longer a member" do
    assert Mirror.member_of_group?(["jane.doe@demo.atlassian.net"], "confluence-users")

    {:ok, _} = Mirror.replace_group_members("confluence-users", [])

    refute Mirror.member_of_group?(["jane.doe@demo.atlassian.net"], "confluence-users")
  end

  test "groups the content refers to are reported with Confluence's spelling" do
    assert {"product-team", "product-team"} in Mirror.referenced_groups()
    assert {"confluence-users", "confluence-users"} in Mirror.referenced_groups()
  end
end
