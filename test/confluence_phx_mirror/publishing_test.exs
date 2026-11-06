defmodule ConfluencePhxMirror.PublishingTest do
  @moduledoc """
  Three settings, all off unless a deployment asks for them, and the two seams
  that read them: a byline, and whether comments are published at all.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirror.TestConfig
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter

  test "a mirror publishes to the people it admitted unless it says otherwise" do
    refute Publishing.public_site?()
    refute Publishing.anonymise_contributors?()
    refute Publishing.exclude_comments?()

    TestConfig.put(:public_site, true)
    TestConfig.put(:anonymize_contributors, true)
    TestConfig.put(:exclude_comments, true)

    assert Publishing.public_site?()
    assert Publishing.anonymise_contributors?()
    assert Publishing.exclude_comments?()
  end

  test "a byline is the name while names are published" do
    assert Publishing.byline("Jane Doe") == "Jane Doe"
    assert Publishing.byline(nil) == nil
    assert Publishing.byline("") == nil
  end

  test "a deployment that publishes no names answers with none" do
    TestConfig.put(:anonymize_contributors, true)

    assert Publishing.byline("Jane Doe") == nil
  end

  test "the API borrows the same byline" do
    space = space_fixture(%{key: "PUB"})
    comment = comment_fixture(page_fixture(space, %{confluence_id: 97_040}))

    assert Presenter.comment(comment)["history"]["createdBy"]["displayName"] == "Sam Rivera"

    TestConfig.put(:anonymize_contributors, true)

    assert Presenter.comment(comment)["history"]["createdBy"]["displayName"] == nil
  end

  test "a deployment that publishes no comments reads none" do
    space = space_fixture(%{key: "PUB"})
    page = page_fixture(space, %{confluence_id: 97_041})
    comment_fixture(page)

    assert length(Mirror.comments(page)) == 1

    TestConfig.put(:exclude_comments, true)

    assert Mirror.comments(page) == []
  end

  describe "the boot report" do
    test "no switches means the people this deployment admitted" do
      assert Publishing.describe() == "publishing to admitted readers only"
    end

    test "a public site with no list leaves the permissions to decide" do
      TestConfig.put(:public_site, true)

      assert Publishing.describe() =~ "every space the permissions leave open"
    end

    test "a list names the spaces a stranger may read, and says they are anonymised" do
      TestConfig.put(:public_site, true)
      TestConfig.put(:public_spaces, ["eng", "ops"])

      assert Publishing.describe() ==
               "public spaces ENG, OPS: a stranger reads those, and they are anonymised"
    end

    test "a list without the public site says so, because it grants nothing on its own" do
      TestConfig.put(:public_spaces, ["ENG"])

      assert Publishing.describe() =~ "inert without CM_PUBLIC_SITE"
    end
  end

  describe "a public subset of the spaces" do
    test "no list means no space is public" do
      assert Publishing.public_spaces() == []

      refute Publishing.public_space?("ENG")
    end

    test "the list names the spaces a stranger may read, in whatever case it was written" do
      TestConfig.put(:public_spaces, [" eng", "OPS"])

      assert Publishing.public_spaces() == ["ENG", "OPS"]
      assert Publishing.public_space?("eng")
      assert Publishing.public_space?("Ops")
      refute Publishing.public_space?("HR")
      refute Publishing.public_space?(nil)
    end

    test "a stranger on a public deployment is shown nobody, without being asked to remember a flag" do
      TestConfig.put(:public_site, true)

      refute Publishing.identities?(Scope.for_user(nil))
    end

    test "a reader with an account sees the same page as before" do
      TestConfig.put(:public_site, true)

      assert Publishing.identities?(Scope.for_user(user_fixture()))
    end

    test "a stored body of a public space names nobody, because one copy is served to everybody" do
      TestConfig.put(:public_spaces, ["ENG"])

      refute Publishing.identities_in_space?("ENG")
      assert Publishing.identities_in_space?("HR")
    end

    test "a stored body names nobody either when the deployment publishes no names" do
      TestConfig.put(:anonymize_contributors, true)

      refute Publishing.identities_in_space?("HR")
    end

    test "a public deployment's stored bodies name nobody, whatever space they came from" do
      TestConfig.put(:public_site, true)

      refute Publishing.identities_in_space?("HR")
      refute Publishing.identities_in_space?(nil)
    end

    test "a query that spans spaces keeps names only when nothing is published at all" do
      assert Publishing.identities_anywhere?()

      TestConfig.put(:public_spaces, ["ENG"])

      refute Publishing.identities_anywhere?()
    end
  end
end
