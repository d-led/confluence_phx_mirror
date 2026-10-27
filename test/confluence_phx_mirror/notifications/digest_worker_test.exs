defmodule ConfluencePhxMirror.Notifications.DigestWorkerTest do
  @moduledoc """
  The daily digest: one mail per reader for what they have not been told yet,
  and every entry marked the way its delivery went.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.{Demo, Mirror, Notifications, Settings}
  alias ConfluencePhxMirror.Notifications.DigestWorker

  setup do
    demo_snapshot!()
    # The cache outlives a test; start from what the table actually holds.
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "a reader with unsent updates gets one mail, and they are marked delivered" do
    {subscriber, _page} = subscriber_with_unsent_update()
    digest_due_now()

    assert :ok = DigestWorker.perform(%Oban.Job{})

    assert_email_sent(fn email ->
      assert email.subject == "[Mirror] 1 page updates"
      assert email.to == [{display_name(subscriber), subscriber.email}]
    end)

    assert Notifications.pending_digest() == %{}
  end

  test "at any other hour it says nothing and leaves the updates waiting" do
    {_subscriber, _page} = subscriber_with_unsent_update()
    digest_due_at(rem(DateTime.utc_now().hour + 1, 24))

    assert :ok = DigestWorker.perform(%Oban.Job{})

    refute_email_sent()
    assert Notifications.pending_digest() != %{}
  end

  test "a refused delivery is recorded and the job fails, so Oban retries" do
    {_subscriber, _page} = subscriber_with_unsent_update()
    digest_due_now()
    refuse_deliveries()

    assert {:error, :smtp_down} = DigestWorker.perform(%Oban.Job{})

    assert [%{error: error}] = Notifications.recent()
    assert error =~ "smtp_down"
    assert Notifications.pending_digest() == %{}
  end

  defp subscriber_with_unsent_update do
    subscriber = user_fixture()
    {:ok, page} = Mirror.find_page(Demo.open_page())
    {:ok, _subscription} = Notifications.subscribe(subscriber, "page", page.id)
    [_notification] = Notifications.page_changed(page, :updated)
    {subscriber, page}
  end

  defp digest_due_now, do: digest_due_at(DateTime.utc_now().hour)

  defp digest_due_at(hour) do
    {:ok, _applied} =
      Settings.update(%{"notifications.digest_hour_utc" => hour}, {:system, "test"})
  end

  defp refuse_deliveries do
    config = Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Mailer, [])

    Application.put_env(
      :confluence_phx_mirror,
      ConfluencePhxMirror.Mailer,
      Keyword.put(config, :adapter, ConfluencePhxMirror.FailingMailer)
    )

    on_exit(fn ->
      Application.put_env(:confluence_phx_mirror, ConfluencePhxMirror.Mailer, config)
    end)
  end

  # `Email.digest/2` addresses the reader the same way every other mail does.
  defp display_name(user), do: ConfluencePhxMirror.Accounts.User.display_name(user)
end
