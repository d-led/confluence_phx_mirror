defmodule ConfluencePhxMirror.TrashTest do
  @moduledoc """
  Trashing is what a sync does; purging is what an administrator does.

  A page, a blog post, a comment or a space that disappears in Confluence stops
  being readable here, but keeps its rows — and its comments with it — until
  someone empties the trash, which is the only thing that deletes content.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Confluence.{NoSpacesSource, SpaceDroppingSource}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Trash

  defp comment_fixture(page, attrs \\ %{}) do
    id = Map.get(attrs, :confluence_id) || System.unique_integer([:positive])

    {:ok, comment} =
      %Comment{}
      |> Comment.changeset(
        Map.merge(
          %{
            confluence_id: id,
            page_id: page.id,
            author_name: "Reader",
            body_export: "<p>a comment</p>"
          },
          attrs
        )
      )
      |> Repo.insert()

    comment
  end

  describe "a page that disappears upstream" do
    test "is trashed with its comments" do
      space = space_fixture()
      page = page_fixture(space)
      comment = comment_fixture(page)

      Mirror.mark_missing_deleted(space, [])

      assert Repo.get(Page, page.id).deleted_at
      assert Repo.get(Comment, comment.id).deleted_at
      assert Mirror.comments(Repo.get(Page, page.id)) == []
    end

    test "a blog post takes the same path" do
      space = space_fixture()
      post = page_fixture(space, %{type: "blogpost"})
      comment = comment_fixture(post)

      Mirror.mark_missing_deleted(space, [])

      assert Repo.get(Page, post.id).deleted_at
      assert Repo.get(Comment, comment.id).deleted_at
    end
  end

  describe "a space that disappears upstream" do
    test "is trashed with its pages and their comments, and stops being readable" do
      kept = space_fixture(%{key: "KEEP"})
      gone = space_fixture(%{key: "GONE"})
      page = page_fixture(gone)
      comment = comment_fixture(page)

      assert [{gone_space, 1}] = Mirror.prune_missing_spaces(["KEEP"])
      assert gone_space.id == gone.id

      assert Mirror.get_space_by_key("GONE") == nil
      assert Enum.map(Mirror.list_spaces(), & &1.key) == ["KEEP"]
      assert Repo.get(Space, gone.id).deleted_at
      assert Repo.get(Page, page.id).deleted_at
      assert Repo.get(Comment, comment.id).deleted_at
      assert Mirror.get_space_by_key("KEEP").id == kept.id
    end

    test "a snapshot trashes a space the source stopped listing" do
      {:ok, _run} = Sync.run(:snapshot, source: SpaceDroppingSource)
      assert Mirror.get_space_by_key("PROD")

      Application.put_env(:confluence_phx_mirror, SpaceDroppingSource, drop: ["PROD"])
      on_exit(fn -> Application.delete_env(:confluence_phx_mirror, SpaceDroppingSource) end)

      {:ok, run} = Sync.run(:snapshot, source: SpaceDroppingSource)

      assert run.stats["spaces_trashed"] == 1
      assert Mirror.get_space_by_key("PROD") == nil
      assert Mirror.get_space_by_key("ENG")
    end

    test "a page that comes back is live again" do
      space = space_fixture()
      page = page_fixture(space)

      Mirror.mark_missing_deleted(space, [])
      assert Repo.get(Page, page.id).deleted_at

      page_fixture(space, %{confluence_id: page.confluence_id})

      refute Repo.get(Page, page.id).deleted_at
      assert Mirror.get_space_by_key(space.key)
    end

    test "a space that comes back is live again" do
      space = space_fixture(%{key: "RETURN"})
      page = page_fixture(space)

      [{trashed, 1}] = Mirror.prune_missing_spaces([])
      assert trashed.id == space.id
      assert Repo.get(Space, space.id).deleted_at

      space_fixture(%{key: "RETURN"})
      page_fixture(space, %{confluence_id: page.confluence_id})

      refute Repo.get(Space, space.id).deleted_at
      refute Repo.get(Page, page.id).deleted_at
      assert Mirror.get_space_by_key("RETURN")
    end

    test "an empty space listing trashes nothing" do
      {:ok, _run} = Sync.run(:snapshot)

      {:ok, run} = Sync.run(:snapshot, source: NoSpacesSource)

      assert run.stats["spaces_trashed"] == 0
      assert Mirror.get_space_by_key("ENG")
      assert Mirror.get_space_by_key("PROD")
    end

    # A space with no pages moves no page row, so the cached totals have to
    # notice the space itself.
    test "the totals stop counting a space the moment it is trashed" do
      doomed = space_fixture(%{key: "DOOMED"})
      before = Mirror.stats()

      assert Mirror.trash_space(doomed) == 0

      assert %{spaces: spaces, pages: pages} = Mirror.stats()
      assert spaces == before.spaces - 1
      assert pages == before.pages
    end

    test "a trashed space takes its pages out of the totals" do
      space = space_fixture(%{key: "FULL"})
      page_fixture(space)
      before = Mirror.stats()

      assert Mirror.trash_space(space) == 1

      assert %{spaces: spaces, pages: pages} = Mirror.stats()
      assert spaces == before.spaces - 1
      assert pages == before.pages - 1
    end
  end

  describe "emptying the trash" do
    test "a trashed page takes its comments and its blobs with it" do
      space = space_fixture()
      page = page_fixture(space)
      comment = comment_fixture(page)
      {:ok, key} = Store.put("spaces/#{space.key}/pages/#{page.confluence_id}/note.txt", "hello")
      attachment = attachment_fixture(page, %{blob_key: key})

      Mirror.mark_missing_deleted(space, [])

      assert {:ok, :page} = Trash.purge_page({:system, "test"}, Repo.get(Page, page.id))

      assert Repo.get(Page, page.id) == nil
      assert Repo.get(Comment, comment.id) == nil
      assert Repo.get(Attachment, attachment.id) == nil
      refute Store.exists?(key)
    end

    test "a trashed space takes everything in it" do
      space = space_fixture(%{key: "DUMP"})
      page = page_fixture(space)
      comment = comment_fixture(page)
      {:ok, key} = Store.put("spaces/DUMP/pages/#{page.confluence_id}/diagram.svg", "<svg/>")
      attachment = attachment_fixture(page, %{blob_key: key})

      assert Mirror.trash_space(space) == 1

      assert {:ok, %{pages: 1}} = Trash.purge_space({:system, "test"}, Repo.get(Space, space.id))

      assert Repo.get(Space, space.id) == nil
      assert Repo.get(Page, page.id) == nil
      assert Repo.get(Comment, comment.id) == nil
      assert Repo.get(Attachment, attachment.id) == nil
      refute Store.exists?(key)
    end

    test "refuses anything that is still live" do
      space = space_fixture()
      page = page_fixture(space)

      assert Trash.purge_space({:system, "test"}, space) == {:error, :not_trashed}
      assert Trash.purge_page({:system, "test"}, page) == {:error, :not_trashed}
    end
  end
end
