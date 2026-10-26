defmodule ConfluencePhxMirror.Mirror.PeopleTest do
  @moduledoc """
  The site's side of the story: which people the content names, and which
  groups the sync read for each of them.
  """
  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror

  test "membership can be recorded one person at a time" do
    {:ok, 2} =
      Mirror.replace_subject_groups(
        %{account_id: "557058:jane.doe", display_name: "Jane Doe"},
        ["confluence-users", "product-team"]
      )

    assert Mirror.member_of_group?(["557058:jane.doe"], "Product-Team")
  end

  test "learning an account's groups again replaces what it had" do
    identity = %{email: "Jane@Example.com", display_name: "Jane"}

    {:ok, _} = Mirror.replace_subject_groups(identity, ["confluence-users"])
    {:ok, _} = Mirror.replace_subject_groups(identity, ["confluence-admins"])

    refute Mirror.member_of_group?(["jane@example.com"], "confluence-users")
    assert Mirror.member_of_group?(["jane@example.com"], "confluence-admins")
  end

  test "the people the content names are listed once each, with their groups" do
    space = space_fixture()

    page_fixture(space, %{author_name: "Jane Doe", author_account_id: "557058:jane"})
    page_fixture(space, %{author_name: "Jane Doe", author_account_id: "557058:jane"})

    {:ok, _} = Mirror.replace_subject_groups(%{account_id: "557058:jane"}, ["confluence-users"])

    assert [%{display_name: "Jane Doe", groups: ["confluence-users"]}] = Mirror.people()
  end

  test "an account that only ever commented is a person too" do
    space = space_fixture()
    page = page_fixture(space)

    comment_fixture(page, %{author_name: "Sam Rivera", author_account_id: "557058:sam"})

    assert Enum.map(Mirror.known_identities(), & &1.display_name) == ["Sam Rivera"]
  end
end
