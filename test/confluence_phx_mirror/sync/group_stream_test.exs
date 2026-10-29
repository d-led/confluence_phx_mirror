defmodule ConfluencePhxMirror.Sync.GroupStreamTest do
  @moduledoc """
  A site that pages a group's members is read a page at a time, and every member
  becomes a mirrored person.

  This is the direction Confluence Cloud still answers, and the one that reaches
  the people who never authored anything and have not signed in yet: an
  administrator can see them — and link their identities — before their first
  visit.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  alias ConfluencePhxMirror.Confluence.PagedGroupSource
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.TestConfig

  test "every group the site lists is read, a page at a time" do
    assert {:ok, run} = Sync.run(:snapshot, source: PagedGroupSource)

    assert run.stats["group_members"] == 4
    assert Mirror.group_catalogue() |> Enum.map(& &1.name) |> Enum.sort() == ["robot", "staff"]
    assert Mirror.group("staff").members == 3
    assert [%{display_name: "Chat"}] = Mirror.group_members("robot")
  end

  test "a member the site no longer lists loses the group" do
    assert {:ok, _run} = Sync.run(:snapshot, source: PagedGroupSource)

    TestConfig.put(:paged_group_source, [
      %{
        name: "staff",
        id: "8f14e45f",
        pages: [[%{account_id: "557058:bert", display_name: "Bert Lindner"}]]
      }
    ])

    assert {:ok, _run} = Sync.run(:snapshot, source: PagedGroupSource)

    assert Mirror.member_of_group?(["557058:bert"], "staff")
    refute Mirror.member_of_group?(["557058:karsten"], "staff")
  end

  test "a person the site only names in a group is listed, and can be linked" do
    assert {:ok, _run} = Sync.run(:snapshot, source: PagedGroupSource)

    assert [%{account_id: "557058:birgit", display_name: "Birgit Grossmann"}] =
             Mirror.people(query: "grossmann")

    assert Mirror.identity_known?(["557058:birgit"])
  end
end
