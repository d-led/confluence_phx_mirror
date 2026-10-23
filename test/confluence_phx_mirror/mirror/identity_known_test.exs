defmodule ConfluencePhxMirror.Mirror.IdentityKnownTest do
  @moduledoc """
  "Known" is a fact about the mirror's own tables: Confluence Cloud has no way to
  list a site's users, so the sync can only vouch for people it has seen — a
  group member, or somebody a permission names.
  """

  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror

  test "a member of a synced group is known, whatever the case of the address" do
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{email: "Jane@Example.com"}])

    assert Mirror.identity_known?(["jane@example.com"])
    refute Mirror.identity_known?(["jane@example.org"])
  end

  test "a user named in a space permission is known" do
    space = space_fixture()

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "user", subject_key: "Bob@Example.com"}
      ])

    assert Mirror.identity_known?(["bob@example.com"])
  end

  test "a user named in a page restriction is known" do
    page = page_fixture(space_fixture())

    {:ok, _} =
      Mirror.replace_page_restrictions(page, [
        %{operation: "read", subject_type: "user", subject_key: "carol@example.com"}
      ])

    assert Mirror.identity_known?(["carol@example.com"])
  end

  test "a Confluence account id is enough on its own" do
    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [%{account_id: "557058:jane.doe"}])

    assert Mirror.identity_known?(["557058:jane.doe"])
  end

  test "an identity with no evidence anywhere is not known" do
    refute Mirror.identity_known?(["stranger@example.com"])
    refute Mirror.identity_known?([])
    refute Mirror.identity_known?([nil])
  end
end
