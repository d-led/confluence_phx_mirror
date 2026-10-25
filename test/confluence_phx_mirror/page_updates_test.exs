defmodule ConfluencePhxMirror.PageUpdatesTest do
  @moduledoc """
  A page a sync finishes is announced to whoever is reading it — once, after the
  transaction that wrote it has committed, and with the moment the mirror read
  it, which is what lets a tab that already has that copy stay quiet.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.PageUpdates
  alias ConfluencePhxMirror.Sync

  test "a page a run writes is announced with when the mirror read it" do
    demo_snapshot!()

    {:ok, before} = Mirror.find_page(1002)
    PageUpdates.subscribe(before.id)

    assert {:ok, run} = Sync.run(:page, confluence_id: 1002)
    assert run.status == "succeeded"

    assert_receive {:page_synced, page_id, at}, 30_000

    assert page_id == before.id
    assert at > DateTime.to_iso8601(before.synced_at)
  end

  test "a page the run does not reach is not announced" do
    demo_snapshot!()

    {:ok, untouched} = Mirror.find_page(1003)
    PageUpdates.subscribe(untouched.id)

    assert {:ok, _run} = Sync.run(:page, confluence_id: 1002)

    refute_receive {:page_synced, _, _}, 500
  end
end
