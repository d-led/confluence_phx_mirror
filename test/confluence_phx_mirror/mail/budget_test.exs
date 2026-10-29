defmodule ConfluencePhxMirror.Mail.BudgetTest do
  @moduledoc """
  The provider's day, spent by counting rather than by being refused.

  Two messages a day is the allowance here: a figure small enough to spend inside
  a test, and the same arithmetic whatever the relay's own number is.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Mail.Budget
  alias ConfluencePhxMirror.Settings

  @actor {:system, "test"}

  setup do
    Settings.update(%{"mail.per_day" => "2"}, @actor)
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "each message takes one of the day's messages" do
    assert Budget.remaining() == 2

    assert {:ok, _} = Budget.claim("watcher:1")
    assert Budget.remaining() == 1
  end

  test "the day runs out, and says how long until it does not" do
    assert {:ok, _} = Budget.claim("watcher:1")
    assert {:ok, _} = Budget.claim("watcher:2")

    assert {:error, :spent, seconds} = Budget.claim("watcher:3")
    assert seconds > 0
    assert Budget.remaining() == 0
  end

  test "a message that went is not sent twice" do
    assert {:ok, send} = Budget.claim("watcher:1")
    assert :ok = Budget.mark_sent(send)

    assert {:error, :already_sent} = Budget.claim("watcher:1")
  end

  test "a refused message frees its name but keeps its place in the day" do
    assert {:ok, send} = Budget.claim("watcher:1")
    assert :ok = Budget.mark_failed(send, :smtp_down)

    assert Budget.used() == 1, "the relay was asked, so the day was spent on it"
    assert {:ok, _retry} = Budget.claim("watcher:1"), "the message itself never went"
  end

  test "a message with no name is not deduplicated" do
    assert {:ok, _} = Budget.claim(nil)
    assert {:ok, _} = Budget.claim(nil)

    assert {:error, :spent, _} = Budget.claim(nil)
  end

  test "yesterday's allowance is not today's" do
    assert {:ok, send} = Budget.claim("yesterday:1")
    assert :ok = Budget.mark_sent(send)
    backdate(send)

    assert Budget.used() == 0
    assert Budget.remaining() == 2
  end

  # The day is UTC, so a row from before midnight belongs to the day before.
  defp backdate(send) do
    yesterday = Date.add(Date.utc_today(), -1)

    ConfluencePhxMirror.Repo.update_all(
      Ecto.Query.from(s in ConfluencePhxMirror.Mail.Send, where: s.id == ^send.id),
      set: [day: yesterday]
    )
  end
end
