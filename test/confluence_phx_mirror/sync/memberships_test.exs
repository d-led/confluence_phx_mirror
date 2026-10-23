defmodule ConfluencePhxMirror.Sync.MembershipsTest do
  @moduledoc """
  Confluence Cloud answers "which groups is this account in" but no longer "who
  is in this group", so a live sync learns membership from the people its
  content names.
  """
  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Confluence.MembershipSource
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync

  test "the people the content names end up in the groups the site reports" do
    assert {:ok, run} = Sync.run(:snapshot, source: MembershipSource)

    assert run.stats["group_members"] > 0
    assert Mirror.group_members("mirrored-group") != []
  end

  test "an author with no mirror account is still mirrored as a group member" do
    assert {:ok, _run} = Sync.run(:snapshot, source: MembershipSource)

    jane = Enum.find(Mirror.known_identities(), &(&1.display_name == "Jane Doe"))

    assert Mirror.member_of_group?([jane.account_id], "mirrored-group")
  end
end
