defmodule ConfluencePhxMirror.Notifications.EmailWorkerTest do
  @moduledoc """
  What the queue does when it is asked twice, and when the provider's day is
  spent.

  Both are properties of the *queue*, not of the message: a retried job must not
  become a second mail, and a full day must become a wait rather than a failure.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.{Mail, Repo, Settings}
  alias ConfluencePhxMirror.Notifications.EmailWorker
  alias ConfluencePhxMirror.Notifications.Notification

  @actor {:system, "test"}

  setup do
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "a message the relay already took is not sent a second time" do
    notification = notification_fixture()

    assert :ok = EmailWorker.perform(job(notification))
    assert_email_sent(fn email -> assert email.subject == notification.subject end)

    # What a crash between the send and the marking leaves behind: the mail went
    # out, and the row still says it did not.
    forget_delivery(notification)

    assert :ok = EmailWorker.perform(job(notification))
    refute_email_sent()
  end

  test "a day whose allowance is spent waits for midnight instead of failing" do
    Settings.update(%{"mail.per_day" => "1"}, @actor)
    assert {:ok, _row} = Mail.Budget.claim("something:else")

    assert {:snooze, seconds} = EmailWorker.perform(job(notification_fixture()))
    assert seconds > 0
    refute_email_sent()
  end

  test "a notification that is gone is done, not an error" do
    notification = notification_fixture()
    Repo.delete!(notification)

    assert :ok = EmailWorker.perform(job(notification))
  end

  defp job(notification) do
    %Oban.Job{args: %{"notification_id" => notification.id}}
  end

  defp notification_fixture do
    page = page_fixture(space_fixture())
    reader = user_fixture(%{email: "watcher#{System.unique_integer([:positive])}@example.com"})

    %Notification{}
    |> Notification.changeset(%{
      user_id: reader.id,
      page_id: page.id,
      kind: "page_updated",
      subject: "[Mirror] #{page.title} changed",
      body: "The page changed."
    })
    |> Repo.insert!()
  end

  # The write that a crash can lose: the mail went, and the row still says it
  # did not.
  defp forget_delivery(notification) do
    Repo.update_all(
      from(n in Notification, where: n.id == ^notification.id),
      set: [delivered_at: nil]
    )
  end
end
