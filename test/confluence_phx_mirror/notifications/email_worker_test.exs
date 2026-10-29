defmodule ConfluencePhxMirror.Notifications.EmailWorkerTest do
  @moduledoc """
  Notifications are debounced: a burst of changes is one job and one message.

  A sync is one morning's work to the site and, to a reader watching a space,
  one message — not a hundred. What matters here is the whole of that: the burst
  costs one job, the message names every page in it with a link, a second burst
  is a second message, and a reader's burst is nobody else's.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.{Mail, Notifications, Repo, Settings}
  alias ConfluencePhxMirror.Notifications.EmailWorker

  @actor {:system, "test"}

  setup do
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "a burst of fifty changes is one job and one message" do
    {reader, space} = reader_watching_a_space()
    Enum.each(1..50, &change_page(&1, space))

    assert [job] = all_enqueued(worker: EmailWorker), "one job for the whole burst"

    assert :ok = EmailWorker.perform(job)

    assert_email_sent(fn email ->
      assert email.to == [{reader.display_name, reader.email}]
      assert email.subject == "[Mirror] 50 pages you watch changed"
      assert length(String.split(email.html_body, "version 2")) >= 50
    end)

    assert Notifications.pending_for(reader.id) == [], "everything it named is delivered"
  end

  test "a change after the send is a second message, and only carries itself" do
    {_reader, space} = reader_watching_a_space()
    change_page(1, space)

    [first] = all_enqueued(worker: EmailWorker)
    assert :ok = EmailWorker.perform(first)
    assert_email_sent()

    # Calling `perform/1` by hand does not move the row out of `scheduled` the
    # way Oban does after a run, and the next schedule is unique against it.
    :ok = Oban.cancel_job(first)

    change_page(2, space)

    assert [second] = all_enqueued(worker: EmailWorker, state: :scheduled)
    assert second.id != first.id, "a new job, not the one that already ran"

    assert :ok = EmailWorker.perform(second)
    assert_email_sent(fn email -> assert email.subject =~ "Page 2" end)
  end

  test "one reader's burst is not another's" do
    {first_reader, space} = reader_watching_a_space("first@example.com")
    {second_reader, _same} = reader_watching_a_space("second@example.com", space)

    change_page(1, space)

    jobs = all_enqueued(worker: EmailWorker)
    assert length(jobs) == 2, "one job per reader"

    # By reader, not by the order the rows were written: which subscriber the
    # database listed first is not something a test should depend on.
    first_job = Enum.find(jobs, &(&1.args["user_id"] == first_reader.id))
    second_job = Enum.find(jobs, &(&1.args["user_id"] == second_reader.id))
    assert first_job && second_job

    # Each reader's mail is checked where it is sent: the test assertion looks at
    # the last message, and both of these are messages.
    assert :ok = EmailWorker.perform(first_job)

    assert_email_sent(fn email ->
      assert email.to == [{first_reader.display_name, first_reader.email}]
    end)

    assert :ok = EmailWorker.perform(second_job)

    assert_email_sent(fn email ->
      assert email.to == [{second_reader.display_name, second_reader.email}]
    end)
  end

  test "the message names the page, its space, its version and a link" do
    {_reader, space} = reader_watching_a_space()
    change_page(7, space)

    [job] = all_enqueued(worker: EmailWorker)
    assert :ok = EmailWorker.perform(job)

    assert_email_sent(fn email ->
      assert email.html_body =~ space.key
      assert email.html_body =~ "version 2"
      assert email.html_body =~ "/spaces/#{space.key}/pages/"
    end)
  end

  test "a day whose allowance is spent leaves the changes waiting" do
    {reader, space} = reader_watching_a_space()
    Settings.update(%{"mail.per_day" => "1"}, @actor)
    assert {:ok, _row} = Mail.Budget.claim("something:else")
    change_page(1, space)

    [job] = all_enqueued(worker: EmailWorker)

    assert {:snooze, seconds} = EmailWorker.perform(job)
    assert seconds > 0
    refute_email_sent()
    assert length(Notifications.pending_for(reader.id)) == 1
  end

  test "a paused queue waits instead of sending" do
    {reader, space} = reader_watching_a_space()
    Settings.update(%{"mail.paused" => "true"}, @actor)
    change_page(1, space)

    [job] = all_enqueued(worker: EmailWorker)

    assert {:snooze, 60} = EmailWorker.perform(job)
    refute_email_sent()
    assert length(Notifications.pending_for(reader.id)) == 1
  end

  test "a reader with nothing pending is a no-op" do
    {reader, _space} = reader_watching_a_space()

    assert :ok = EmailWorker.perform(%Oban.Job{args: %{"user_id" => reader.id}})
    refute_email_sent()
  end

  defp reader_watching_a_space(email \\ "watcher@example.com", space \\ space_fixture()) do
    reader = user_fixture(%{email: email})
    {:ok, _subscription} = Notifications.subscribe(reader, "space", space.id)
    {reader, space}
  end

  defp change_page(number, space) do
    page =
      page_fixture(space, %{
        title: "Page #{number}",
        confluence_id: number,
        version_number: 2
      })

    Notifications.page_changed(Repo.preload(page, :space), :updated)
  end
end
