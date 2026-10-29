defmodule ConfluencePhxMirrorWeb.Live.Admin.MailLiveTest do
  @moduledoc """
  The mail queue as an operator meets it: what is waiting, whether it may go,
  and what purging it costs.

  The screen is the second half of the pause — the switch itself is a setting —
  so what it has to get right is that the three counts, the queue and the two
  buttons agree with the outbox after every click.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.{Notifications, Settings, TestConfig}

  setup do
    demo_snapshot!()
    TestConfig.put(:mail_paused, false)
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "the queue shows what is waiting and how much has gone", %{conn: conn} do
    waiting = queued_notification_fixture()

    {:ok, view, _html} = live(sign_in(conn), ~p"/admin/mail")

    assert has_element?(view, "#mail-queued-#{waiting.id}")
    assert view |> element("#mail-count-waiting") |> render() =~ "1"
    assert view |> element("#mail-count-delivered") |> render() =~ "0"
  end

  test "an empty queue says so instead of showing an empty table", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn), ~p"/admin/mail")

    assert has_element?(view, "#mail-queue-empty")
    refute has_element?(view, "#mail-queue table")
  end

  test "pausing stops the drain, and the screen says which way it went", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn), ~p"/admin/mail")

    html = view |> element("#mail-pause") |> render_click()

    assert html =~ "Mail is paused"
    assert has_element?(view, "#mail-paused")
    assert Settings.mail_paused?()

    view |> element("#mail-pause") |> render_click()

    refute has_element?(view, "#mail-paused")
    refute Settings.mail_paused?()
  end

  test "purging empties the queue and leaves the delivered rows alone", %{conn: conn} do
    sent = queued_notification_fixture()
    {:ok, _} = Notifications.mark_delivered(sent)
    queued_notification_fixture()

    {:ok, view, _html} = live(sign_in(conn), ~p"/admin/mail")

    view |> element("#mail-purge") |> render_click()

    assert Notifications.queue() == []
    assert view |> element("#mail-count-waiting") |> render() =~ "0"
    assert view |> element("#mail-count-delivered") |> render() =~ "1"
  end

  describe "the day's ledger" do
    test "counts a test message against the allowance and lists it", %{conn: conn} do
      reader = user_fixture(%{email: "ledger.reader@example.com"})

      assert :ok = ConfluencePhxMirror.Mail.send_test(reader)

      {:ok, view, _html} = live(sign_in(conn), ~p"/admin/mail")

      # The queue is watchers' mail and says nothing about this message; the
      # ledger is where it is, and it spends one of the day's allowance.
      assert has_element?(view, "#mail-queue-empty")
      assert view |> element("#mail-count-today") |> render() =~ "1"
      assert has_element?(view, "#mail-today tr", "test message")
    end

    test "says so when nothing has been handed over today", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn), ~p"/admin/mail")

      assert has_element?(view, "#mail-today-empty")
      assert view |> element("#mail-count-today") |> render() =~ "0"
    end
  end

  test "a reader who is not an administrator does not get the screen", %{conn: conn} do
    reader = user_fixture(%{email: "no.mail.admin@example.com"})

    assert {:error, {:redirect, %{to: "/"}}} = live(sign_in(conn, reader), ~p"/admin/mail")
  end

  defp sign_in(conn, user \\ nil),
    do: Plug.Test.init_test_session(conn, %{"user_id" => actor(user).id})

  defp actor(nil), do: user_fixture(%{email: "mail.admin@example.com", role: "admin"})
  defp actor(user), do: user
end
