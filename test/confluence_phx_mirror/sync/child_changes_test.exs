defmodule ConfluencePhxMirror.Sync.ChildChangesTest do
  @moduledoc """
  What happens when something other than a page changes in Confluence.

  Comments and attachments carry versions of their own, and neither moves the
  page's. A run that only asked "which pages changed?" would therefore never see
  a new reply — and would report a clean, empty sync while the mirror quietly
  fell behind.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Confluence.{CommentedSource, DemoSource, UnchangedListingSource}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page}
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.Log

  setup do
    clean_blobs()
    Log.clear()
    on_exit(&clean_blobs/0)
    :ok
  end

  defp page!(confluence_id), do: Repo.get_by!(Page, confluence_id: confluence_id)

  # A window that contains nothing: the page did not change, so the only thing
  # that can bring the comment in is asking about the comment itself.
  defp empty_window, do: DateTime.utc_now()

  describe "a comment that arrives without a page edit" do
    setup do
      demo_snapshot!()
      :ok
    end

    test "reaches the mirror on the next incremental run" do
      page = page!(CommentedSource.page_id())
      comments_before = Repo.aggregate(from(c in Comment, where: c.page_id == ^page.id), :count)

      assert {:ok, run} = Sync.run(:incremental, source: CommentedSource, since: empty_window())

      assert run.status == "succeeded"
      assert run.stats["changed"] == 0
      assert run.stats["details_relisted"] == 1

      assert Repo.aggregate(from(c in Comment, where: c.page_id == ^page.id), :count) ==
               comments_before + 1

      comment = Repo.get_by!(Comment, confluence_id: CommentedSource.comment_id())
      assert comment.version_number == 1
      assert comment.body_export =~ "Looks good to me"
    end

    test "the page's own version is left exactly as it was" do
      page!(CommentedSource.page_id())

      assert {:ok, _run} = Sync.run(:incremental, source: CommentedSource, since: empty_window())

      assert page!(CommentedSource.page_id()).version_number == 15
    end

    test "the file pasted into the comment is mirrored and served under the page" do
      assert {:ok, _run} = Sync.run(:incremental, source: CommentedSource, since: empty_window())

      page = page!(CommentedSource.page_id())
      comment = Repo.get_by!(Comment, confluence_id: CommentedSource.comment_id())
      file = Repo.get_by!(Attachment, confluence_id: "att7002")

      assert file.comment_id == comment.id
      assert file.page_id == page.id
      assert file.filename == CommentedSource.filename()
      assert {:ok, bytes} = Store.read(file.blob_key)
      assert bytes == CommentedSource.bytes()

      assert comment.body_export =~
               "/attachments/ENG/#{page.confluence_id}/att7002/#{CommentedSource.filename()}"
    end

    test "the page's own file list does not gain the comment's file" do
      assert {:ok, _run} = Sync.run(:incremental, source: CommentedSource, since: empty_window())

      page = page!(CommentedSource.page_id())
      names = page |> Mirror.attachments() |> Enum.map(& &1.filename)

      refute CommentedSource.filename() in names
    end
  end

  describe "a page whose details were never read" do
    test "is caught up by a later run and says so" do
      demo_snapshot!()

      page = page!(1002)

      Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [details_synced_at: nil])

      assert {:ok, run} = Sync.run(:incremental, source: DemoSource, since: empty_window())

      assert run.stats["details_caught_up"] == 1
      assert page!(1002).details_synced_at != nil
    end
  end

  describe "what a run says about itself" do
    test "names the page it listed and how big the mirror is" do
      demo_snapshot!()
      total = Mirror.count_pages()

      assert {:ok, run} =
               Sync.run(:incremental, source: UnchangedListingSource, since: empty_window())

      assert run.stats["pages"] == 1
      assert run.stats["changed"] == 0
      assert run.stats["unchanged"] == 1
      assert run.stats["total"] == total

      messages = Log.entries() |> Enum.map(& &1.message)
      assert Enum.any?(messages, &(&1 =~ "already current: Architecture Overview"))
    end
  end
end
