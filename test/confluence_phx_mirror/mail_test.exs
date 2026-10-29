defmodule ConfluencePhxMirror.MailTest do
  @moduledoc """
  The test message a reader may send themselves.

  Its whole value is that it reports the truth about the deployment's mail: it
  goes to the reader's own address, it is from the sender in force, and a relay
  that refuses it says so instead of looking like a message that never arrived.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.{Mail, Settings, TestConfig}

  @actor {:system, "test"}

  setup do
    # Storing a sender also publishes it as the app-wide sender, which is
    # global: put the deployment's answer back when this file is done.
    TestConfig.put(:notifications, Application.get_env(:confluence_phx_mirror, :notifications))
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "is for the reader who asked, from the sender in force" do
    reader = user_fixture(%{email: "test.mail@example.com"})

    assert :ok = Mail.send_test(reader)

    assert_email_sent(fn email ->
      assert email.to == [{User.display_name(reader), reader.email}]
      assert email.from == Settings.mail_sender()
      assert email.subject == "[Mirror] Test e-mail"
    end)
  end

  test "is stamped with the sender an administrator stored, not the deployment's" do
    reader = user_fixture(%{email: "stored.sender@example.com"})

    assert {:ok, _stored} =
             Settings.update(
               %{"mail.from" => "mirror@acme.example", "mail.from_name" => "Acme Mirror"},
               @actor
             )

    assert :ok = Mail.send_test(reader)

    assert_email_sent(fn email -> email.from == {"Acme Mirror", "mirror@acme.example"} end)
  end

  test "a second one inside the minute is refused, and nothing goes out" do
    reader = user_fixture(%{email: "once.a.minute@example.com"})

    assert :ok = Mail.send_test(reader)
    assert {:error, :too_soon, retry_after_ms} = Mail.send_test(reader)

    assert retry_after_ms > 0
    assert_email_sent(fn email -> elem(hd(email.to), 1) == reader.email end)
    refute_email_sent()
  end

  # The minute runs from the last message, not from the clock: a bucket that
  # turns over would let two through a second apart.
  test "a minute after the last one, the next is allowed again" do
    reader = user_fixture()

    assert :ok = Mail.send_test(reader)

    {moved, _rows} =
      Repo.update_all(
        from(s in ConfluencePhxMirror.Mail.Send,
          where: like(s.dedup_key, ^"test:#{reader.id}:%")
        ),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -61, :second)]
      )

    assert moved == 1, "the ledger row for this reader is what holds the next message back"

    assert :ok = Mail.send_test(reader)
  end

  test "is in the audit trail, with the reader as the one who asked for it" do
    reader = user_fixture(%{email: "audited.test@example.com"})

    assert :ok = Mail.send_test(reader)

    entry = ConfluencePhxMirror.Audit.recent(1) |> hd()

    assert entry.action == "mail.sent"
    assert entry.entity_type == "message"
    assert entry.actor_type == "user"
    assert entry.metadata["to"] == reader.email
    assert entry.metadata["kind"] == "test", "the kind is read from the message's own name"
  end

  test "a relay that refuses it answers with what it said" do
    reader = user_fixture(%{email: "refused@example.com"})

    TestConfig.put(
      ConfluencePhxMirror.Mailer,
      Keyword.put(
        Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Mailer, []),
        :adapter,
        ConfluencePhxMirror.FailingMailer
      )
    )

    assert {:error, :smtp_down} = Mail.send_test(reader)
  end

  test "a paused queue refuses the test message instead of queueing it" do
    reader = user_fixture(%{email: "paused@example.com"})
    {:ok, _paused} = Settings.update(%{"mail.paused" => true}, @actor)

    assert {:error, :paused} = Mail.send_test(reader)
    refute_email_sent()
  end
end
