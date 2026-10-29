defmodule ConfluencePhxMirror.Notifications.MailQueuePauseTest do
  @moduledoc """
  A paused queue stops without losing anything.

  The pause is a delivery decision, not a failure: both workers come back later,
  the rows stay undelivered, and nothing reaches the relay in the meantime. A
  reader's test message is refused rather than queued, because a diagnostic that
  silently waits would answer a question nobody asked.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.{Notifications, Settings, TestConfig}
  alias ConfluencePhxMirror.Notifications.{DigestWorker, EmailWorker}

  @actor {:system, "test"}

  setup do
    TestConfig.put(:mail_paused, false)
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "the instant worker snoozes, and its row is still waiting afterwards" do
    notification = queued_notification_fixture()
    pause()

    assert {:snooze, seconds} = EmailWorker.perform(job(notification))

    assert seconds > 0
    refute_email_sent()
    assert Notifications.counts().queued == 1
  end

  test "the digest worker snoozes too, and nothing is marked delivered" do
    _notification = queued_notification_fixture()
    digest_due_now()
    pause()

    assert {:snooze, _seconds} = DigestWorker.perform(%Oban.Job{})

    refute_email_sent()
    assert Notifications.pending_digest() != %{}
  end

  test "resuming is what sends what waited, and it goes to the relay once" do
    notification = queued_notification_fixture()
    pause()
    assert {:snooze, _seconds} = EmailWorker.perform(job(notification))

    resume()

    assert :ok = EmailWorker.perform(job(notification))
    assert_email_sent(fn email -> email.subject == notification.subject end)
  end

  defp pause do
    {:ok, _paused} = Settings.update(%{"mail.paused" => true}, @actor)
    :ok
  end

  defp resume do
    {:ok, _resumed} = Settings.update(%{"mail.paused" => false}, @actor)
    :ok
  end

  defp digest_due_now do
    hour = DateTime.utc_now().hour
    {:ok, _stored} = Settings.update(%{"notifications.digest_hour_utc" => hour}, @actor)
    :ok
  end

  defp job(notification) do
    %Oban.Job{args: %{"notification_id" => notification.id}}
  end
end
