defmodule ConfluencePhxMirror.PublishingTest do
  @moduledoc """
  Three settings, all off unless a deployment asks for them, and the two seams
  that read them: a byline, and whether comments are published at all.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

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
end
