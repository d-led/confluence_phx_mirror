defmodule ConfluencePhxMirror.NotificationsTest do
  @moduledoc """
  A subscription records what a reader asked for; whether a message may be sent
  is decided when the page changes, from the permissions as they stand then.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.{Audit, Demo, Jobs, Settings, TestConfig}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Notifications

  setup do
    demo_snapshot!()
    TestConfig.put(:mail_paused, false)
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "a subscriber who may not read the page is not told about it" do
    {:ok, page} = Mirror.find_page(Demo.restricted_page())

    subscriber = user_fixture()
    {:ok, _subscription} = Notifications.subscribe(subscriber, "page", page.id)

    assert Notifications.page_changed(page, :updated) == []
    assert Notifications.recent() == []
  end

  test "a subscriber who may read the page is told" do
    {:ok, page} = Mirror.find_page(Demo.open_page())

    subscriber = user_fixture()
    {:ok, _subscription} = Notifications.subscribe(subscriber, "page", page.id)

    assert [_notification] = Notifications.page_changed(page, :updated)
    assert [%{subject: subject}] = Notifications.recent()
    assert subject =~ page.title
  end

  describe "the mail queue" do
    @actor {:system, "test"}

    test "counts what waits, what the relay refused, and what went" do
      delivered = queued_notification_fixture()
      refused = queued_notification_fixture()

      {:ok, _} = Notifications.mark_delivered(delivered)
      {:ok, _} = Notifications.mark_failed(refused, :smtp_down)

      assert Notifications.counts() == %{queued: 0, failed: 1, delivered: 1}
    end

    test "lists what is still to go out, and leaves the delivered rows out" do
      waiting = queued_notification_fixture()
      sent = queued_notification_fixture()
      {:ok, _} = Notifications.mark_delivered(sent)

      assert [%{id: id}] = Notifications.queue()
      assert id == waiting.id
      assert [%{id: delivered_id}] = Notifications.delivered()
      assert delivered_id == sent.id
    end

    test "a purge drops the queue and the jobs that would send it, and keeps the history" do
      sent = queued_notification_fixture()
      {:ok, _} = Notifications.mark_delivered(sent)
      waiting = queued_notification_fixture()

      assert {:ok, 1} = Notifications.purge_queue(@actor)

      assert Notifications.queue() == []
      assert Notifications.counts() == %{queued: 0, failed: 0, delivered: 1}

      # The job that carried it is cancelled rather than left to fail on a row
      # that is gone — Oban keeps the row, so the job is still there to look at.
      assert Enum.any?(
               Jobs.list("cancelled"),
               &(&1.args["notification_id"] == waiting.id)
             )

      assert %{action: "mail.queue_purged", metadata: %{"deleted" => 1}} =
               Audit.recent(1) |> hd()
    end
  end
end
