defmodule ConfluencePhxMirror.Sync.DetailsInEveryModeTest do
  @moduledoc """
  A page is not its body alone: the comments and the files are read whenever its
  details are, whichever run reached it. The modes differ in *which* pages they
  read — a snapshot reads every listed page, an incremental run the changed ones
  plus a bounded backlog, a one-page run that page — never in what a read
  contains.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync

  @page Demo.open_page_number()

  test "a snapshot gives every listed page its comments and files" do
    demo_snapshot!()

    assert_detailed(@page)
  end

  test "an incremental run details the pages it meets for the first time" do
    assert {:ok, run} = Sync.run(:incremental)
    assert run.status == "succeeded"

    assert_detailed(@page)
  end

  test "a one-page run brings that page's comments and files" do
    assert {:ok, run} = Sync.run(:page, confluence_id: @page)
    assert run.status == "succeeded"

    assert_detailed(@page)
  end

  defp assert_detailed(confluence_id) do
    {:ok, page} = Mirror.find_page(confluence_id)

    assert Mirror.comments(page) != [], "expected the page's comments to be mirrored"

    assert [attachment | _] = Mirror.attachments(page)
    assert attachment.blob_key, "expected the file to have bytes behind it"
    assert Store.exists?(attachment.blob_key)
  end
end
