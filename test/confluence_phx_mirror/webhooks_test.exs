defmodule ConfluencePhxMirror.WebhooksTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.{PageWorker, SpaceWorker}
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirror.Webhooks.Delivery

  @secret "test-webhook-secret"

  defp sign(body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, body), case: :lower)

  defp payload(event, page_id) do
    %{
      "event" => event,
      "page" => %{"id" => to_string(page_id), "title" => "Architecture Overview"},
      "timestamp" => "2026-10-21T09:00:00Z"
    }
  end

  defp deliver(event, page_id, opts \\ []) do
    body = JSON.encode!(payload(event, page_id))
    headers = [{"x-hub-signature-256", Keyword.get(opts, :signature, sign(body))}]
    Webhooks.receive(JSON.decode!(body), body, headers)
  end

  defp deliver_payload(payload) do
    body = JSON.encode!(payload)
    Webhooks.receive(JSON.decode!(body), body, [{"x-hub-signature-256", sign(body)}])
  end

  describe "signatures" do
    test "verifies a valid HMAC over the raw body" do
      assert Webhooks.verify("{}", sign("{}"), @secret)
    end

    test "rejects a tampered body" do
      refute Webhooks.verify(~s({"a":1}), sign(~s({"a":2})), @secret)
    end

    test "rejects legacy header values without the sha256 prefix" do
      raw = "{}"
      unsigned = Base.encode16(:crypto.mac(:hmac, :sha256, @secret, raw), case: :lower)
      assert Webhooks.verify(raw, unsigned, @secret)
    end
  end

  describe "deliveries" do
    test "a valid page event stores the delivery and queues a page sync" do
      assert {:ok, delivery} = deliver("page_updated", 1002)
      assert delivery.signature_valid
      assert delivery.status == "queued"
      assert delivery.processed_at

      assert_enqueued(worker: PageWorker, args: %{"confluence_id" => 1002})
    end

    test "an invalid signature is stored, rejected and not queued" do
      assert {:error, :invalid_signature} =
               deliver("page_updated", 1002, signature: "sha256=deadbeef")

      delivery = Repo.one!(Delivery)
      assert delivery.status == "rejected"
      refute delivery.signature_valid
      failed_jobs = Repo.all(from j in Oban.Job, where: j.worker == ^to_string(PageWorker))
      assert failed_jobs == []
    end

    test "missing signature is rejected" do
      body = JSON.encode!(payload("page_updated", 1002))
      assert {:error, :invalid_signature} = Webhooks.receive(JSON.decode!(body), body, [])
    end

    test "reset events mark the page deleted" do
      demo_snapshot!()
      page = Repo.get_by!(Page, confluence_id: 1002)
      assert is_nil(page.deleted_at)

      assert {:ok, delivery} = deliver("page_removed", 1002)
      assert delivery.status == "processed"

      assert Repo.get!(Page, page.id).deleted_at
      assert {:error, :not_found} = Mirror.find_page(1002)
      refute_enqueued(worker: PageWorker)
    end

    test "unknown pages are recorded as ignored" do
      assert {:ok, delivery} = deliver("page_updated", 999_999)
      assert delivery.status == "queued"

      assert {:ok, delivery} = deliver("page_removed", 999_999)
      assert delivery.status == "ignored"
      assert delivery.error == "page not in mirror"
    end

    test "attachment events queue the container page" do
      assert {:ok, _delivery} =
               deliver_payload(%{
                 "event" => "attachment_created",
                 "attachment" => %{"id" => "9001", "container" => %{"id" => "1002"}}
               })

      assert_enqueued(worker: PageWorker, args: %{"confluence_id" => 1002})
    end

    test "comment events queue the page hosting the comment" do
      assert {:ok, delivery} =
               deliver_payload(%{
                 "event" => "comment_created",
                 "comment" => %{"id" => "3001", "container" => %{"id" => "1002"}}
               })

      assert delivery.status == "queued"
      assert_enqueued(worker: PageWorker, args: %{"confluence_id" => 1002})
    end

    test "space events queue a space sync" do
      assert {:ok, delivery} =
               deliver_payload(%{
                 "event" => "space_updated",
                 "space" => %{"id" => "1", "key" => "ENG"}
               })

      assert delivery.status == "queued"
      assert_enqueued(worker: SpaceWorker, args: %{"space_key" => "ENG"})
    end

    test "space events without a key are recorded as ignored" do
      assert {:ok, delivery} =
               deliver_payload(%{"event" => "space_updated", "space" => %{"id" => "1"}})

      assert delivery.status == "ignored"
      refute_enqueued(worker: SpaceWorker)
    end

    test "event types without a page are ignored" do
      assert {:ok, delivery} = deliver("user_created", 0)
      assert delivery.status == "ignored"
    end
  end
end
