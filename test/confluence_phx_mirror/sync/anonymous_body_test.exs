defmodule ConfluencePhxMirror.Sync.AnonymousBodyTest do
  @moduledoc """
  One stored body is served to every reader, so a page a stranger may read is
  drawn from the body Confluence serves a stranger.

  The rule used to be an assumption — that the two renderings differ only in ways
  the mirror already replaces. They do not: the site's own anonymous body carries
  no person links and no faces, and this is where that is checked rather than
  believed.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  alias ConfluencePhxMirror.Confluence.AnonymousBodySource
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.{Repo, Sync, TestConfig}

  test "a page in a space a stranger may read keeps the stranger's rendering" do
    TestConfig.put(:public_spaces, ["ENG"])

    assert {:ok, _run} = Sync.run(:snapshot, source: AnonymousBodySource)

    page = Repo.get_by!(Page, confluence_id: 1002)

    assert page.body_export =~ "anonymous copy"
    refute page.body_export =~ "signed-in copy"
  end

  # The other half: publishing one space must not change what a page somewhere
  # else is drawn from, even when the source offers both.
  test "a page in a closed space keeps the signed-in rendering" do
    TestConfig.put(:public_spaces, ["ENG"])

    assert {:ok, _run} = Sync.run(:snapshot, source: AnonymousBodySource)

    page = Repo.get_by!(Page, confluence_id: 2000)

    assert page.body_export =~ "signed-in copy"
    refute page.body_export =~ "anonymous copy"
  end

  # Nothing published means every page keeps the signed-in rendering, even
  # though this source offers both: the choice is the publishing rule's, not the
  # source's.
  test "nothing published means every page keeps the signed-in rendering" do
    TestConfig.put(:public_spaces, [])

    assert {:ok, _run} = Sync.run(:snapshot, source: AnonymousBodySource)

    pub = Repo.get_by!(Page, confluence_id: 1002)
    assert pub.body_export =~ "signed-in copy"
    refute pub.body_export =~ "anonymous copy"
  end

  # A deployment that publishes no names asks the same question of every body,
  # whatever space it is in and whether or not anyone outside may read it.
  test "a deployment that publishes no names draws every body from the stranger's" do
    TestConfig.put(:anonymize_contributors, true)

    assert {:ok, _run} = Sync.run(:snapshot, source: AnonymousBodySource)

    closed = Repo.get_by!(Page, confluence_id: 2000)
    assert closed.body_export =~ "anonymous copy"
    refute closed.body_export =~ "signed-in copy"
  end
end
