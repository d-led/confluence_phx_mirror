defmodule ConfluencePhxMirror.SyncTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Confluence.{EditedSource, EmptyListingSource}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Link, Page, Space}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.{EmailWorker, Notification}
  alias ConfluencePhxMirror.Sync

  setup do
    clean_blobs()
    on_exit(&clean_blobs/0)
    :ok
  end

  describe "snapshot" do
    test "mirrors spaces, pages, labels, comments and attachments" do
      assert {:ok, run} = Sync.run(:snapshot)
      assert run.status == "succeeded"
      assert run.stats["spaces"] == 2
      assert run.stats["pages"] == 40

      space = Repo.get_by!(Space, key: "ENG")
      assert Repo.aggregate(from(p in Page, where: p.space_id == ^space.id), :count) == 37

      page = Repo.get_by!(Page, confluence_id: 1002)
      assert page.title == "Architecture Overview"
      assert page.slug == "architecture-overview"
      assert page.labels == ["architecture", "design"]
      assert page.version_number == 15
      assert page.external_url =~ "/wiki/spaces/ENG/pages/1002/"
      assert page.body_export =~ "/attachments/ENG/1002/9001/diagram.svg"
      assert page.body_text =~ "poll"
    end

    test "stores attachment bytes outside Postgres under a readable key" do
      demo_snapshot!()

      attachment = Repo.get_by!(Attachment, confluence_id: 9001)

      assert attachment.blob_key ==
               "spaces/ENG/pages/1002/attachments/9001/diagram.svg"

      assert attachment.media_type == "image/svg+xml"
      assert {:ok, svg} = Store.read(attachment.blob_key)
      assert svg =~ "<svg"
      assert attachment.sha256 == Base.encode16(:crypto.hash(:sha256, svg), case: :lower)
    end

    test "rewrites internal links, keeps unmirrored links absolute and resolves parents" do
      demo_snapshot!()

      page = Repo.get_by!(Page, confluence_id: 1002)
      parent = Repo.get_by!(Page, confluence_id: 1001)

      assert page.parent_id == parent.id
      assert page.ancestors == [1000, 1001]

      links = Repo.all(from l in Link, where: l.source_page_id == ^page.id)

      assert Enum.any?(links, &(&1.kind == "internal" and &1.target_confluence_id == 1001))
      assert Enum.any?(links, &(&1.kind == "attachment"))

      crosslinks = Repo.get_by!(Page, confluence_id: 1006)

      assert crosslinks.body_export =~
               ~s(href="https://demo.atlassian.net/pages/viewpage.action?pageId=9999)

      assert crosslinks.body_export =~ ~s(href="/spaces/PROD/pages/2000/product-hub")
    end

    test "mirrors comments with their replies" do
      demo_snapshot!()

      reply = Repo.get_by!(Comment, confluence_id: 3002)
      parent = Repo.get_by!(Comment, confluence_id: 3001)

      assert reply.parent_id == parent.id
      assert reply.body_export =~ "Contractors"
    end

    test "audits the run and every created page" do
      {:ok, run} = Sync.run(:snapshot)

      assert Repo.exists?(
               from e in Event,
                 where: e.action == "sync.started" and e.entity_id == ^to_string(run.id)
             )

      assert Repo.exists?(
               from e in Event, where: e.action == "page.created" and e.entity_id == "1002"
             )

      assert Repo.exists?(from e in Event, where: e.action == "attachment.mirrored")
    end
  end

  describe "idempotency" do
    test "a second snapshot does not duplicate content or links" do
      demo_snapshot!()

      pages = Repo.aggregate(Page, :count)
      links = Repo.aggregate(Link, :count)
      attachments = Repo.aggregate(Attachment, :count)

      assert {:ok, run} = Sync.run(:snapshot)
      assert run.status == "succeeded"
      assert run.stats["pages"] == 40

      assert Repo.aggregate(Page, :count) == pages
      assert Repo.aggregate(Link, :count) == links
      assert Repo.aggregate(Attachment, :count) == attachments
    end
  end

  describe "page sync" do
    test "picks up a page that changed upstream, bumps the version and reindexes it" do
      demo_snapshot!()
      before = Repo.get_by!(Page, confluence_id: 1002)

      assert {:ok, run} = Sync.run(:page, confluence_id: 1002, source: EditedSource)
      assert run.status == "succeeded"

      after_sync = Repo.get_by!(Page, confluence_id: 1002)

      assert after_sync.version_number == before.version_number + 1
      assert after_sync.version_message == EditedSource.edit_note()
      assert after_sync.body_export =~ "Edited in Confluence"
      assert after_sync.body_text =~ "Edited in Confluence"

      assert Repo.exists?(
               from e in Event,
                 where: e.action == "page.updated" and e.entity_id == "1002"
             )
    end

    test "returns an error when the page does not exist" do
      assert_raise RuntimeError, ~r/not_found/, fn ->
        Sync.run(:page, confluence_id: 999_999)
      end
    end
  end

  describe "notifications" do
    test "subscribers of a page receive an e-mail after an update" do
      demo_snapshot!()
      user = user_fixture(%{email: "reader@example.com"})
      page = Repo.get_by!(Page, confluence_id: 1002)

      {:ok, _} = Notifications.subscribe(user, "page", page.id)

      assert {:ok, _run} = Sync.run(:page, confluence_id: 1002, source: EditedSource)

      notification = Repo.one!(from n in Notification, where: n.user_id == ^user.id)
      assert notification.subject =~ "Architecture Overview"
      assert notification.body =~ "/spaces/ENG/pages/1002/architecture-overview"

      assert_enqueued(worker: EmailWorker)
      assert :ok = perform_job(EmailWorker, %{"notification_id" => notification.id})

      assert_email_sent(fn email ->
        assert email.subject == notification.subject
        assert email.text_body =~ "Architecture Overview"
      end)

      assert Repo.get!(Notification, notification.id).delivered_at
    end

    test "an unchanged page does not notify" do
      demo_snapshot!()
      user = user_fixture(%{email: "quiet@example.com"})
      page = Repo.get_by!(Page, confluence_id: 1002)
      {:ok, _} = Notifications.subscribe(user, "space", page.space_id)

      assert {:ok, _run} = Sync.run(:page, confluence_id: 1002)
      refute Repo.exists?(from n in Notification, where: n.user_id == ^user.id)
    end
  end

  describe "dynamic content" do
    test "bakes label listings and property reports into the page and its search text" do
      demo_snapshot!()
      page = Repo.get_by!(Page, confluence_id: 1003)

      assert page.body_export =~ "Content by label: architecture"
      assert page.body_export =~ ~s(href="/spaces/ENG/pages/1002/architecture-overview")
      assert page.body_export =~ "Page properties report"
      assert page.body_export =~ "Platform"
      assert page.body_text =~ "Page properties report"
    end
  end

  describe "deletions" do
    test "pages missing from a space snapshot are marked deleted but kept for audit" do
      demo_snapshot!()
      space = Repo.get_by!(Space, key: "ENG")
      page = Repo.get_by!(Page, confluence_id: 1009)

      assert Mirror.mark_missing_deleted(space, [1000, 1001, 1002]) >= 1

      deleted = Repo.get!(Page, page.id)
      assert deleted.deleted_at
      assert {:error, :not_found} = Mirror.find_page(1009)
    end

    test "an empty listing from the source never wipes a space" do
      demo_snapshot!()
      pages_before = Repo.aggregate(Page, :count)

      assert {:ok, run} = Sync.run(:snapshot, source: EmptyListingSource)

      assert run.status == "partial"
      assert run.error =~ "empty_listing_kept_existing_pages"
      assert Repo.aggregate(Page, :count) == pages_before
    end

    test "space mode re-reads one space and leaves the others alone" do
      demo_snapshot!()

      assert {:ok, run} = Sync.run(:space, space_key: "PROD")

      assert run.status == "succeeded"
      assert run.stats["spaces"] == 1
      assert {:ok, _page} = Mirror.find_page(2001)
      assert {:ok, _page} = Mirror.find_page(1002)
    end

    test "incremental mode only touches pages that changed upstream" do
      demo_snapshot!()

      assert {:ok, run} =
               Sync.run(:incremental, since: DateTime.add(DateTime.utc_now(), -60, :second))

      assert run.status == "succeeded"
      assert run.stats["pages"] == 0
    end
  end
end
