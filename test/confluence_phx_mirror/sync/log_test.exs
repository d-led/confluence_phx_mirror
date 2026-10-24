defmodule ConfluencePhxMirror.Sync.LogTest do
  @moduledoc """
  The live log keeps what a sync is doing, bounded, and hands it to whoever is
  watching — it never blocks or fails the sync itself.
  """
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.Log

  setup do
    Log.clear()
    :ok
  end

  test "an entry is kept and broadcast to whoever is watching" do
    Log.current_run(7)
    Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, Log.topic())

    Log.add(:info, "page created: Budget", page: 42)

    assert_receive {:sync_log, entry, %{counts: counts, held: 1}}
    assert entry.message == "page created: Budget"
    assert entry.level == :info
    assert entry.run_id == 7
    assert entry.details[:page] == 42
    assert counts == %{debug: 0, info: 1, warn: 0, error: 0}
    assert [^entry] = Log.entries()
  end

  test "entries are kept in the order they happened" do
    Log.add(:info, "first")
    Log.add(:warn, "second")

    assert Enum.map(Log.entries(), & &1.message) == ["first", "second"]
  end

  test "a line says whether it is sync progress, a call to the site or the account" do
    Log.add(:debug, "GET /content 200 42 ms", kind: :http, status: 200)
    Log.add(:info, "page created: Budget")

    assert [call, progress] = Log.entries()
    assert call.kind == :http
    assert call.details == %{status: 200}
    assert progress.kind == :sync
  end

  test "the log is a view, not a record: old lines fall off the end" do
    for index <- 1..420, do: Log.add(:debug, "line #{index}")

    entries = Log.entries()

    assert length(entries) == 400
    assert List.last(entries).message == "line 420"
    assert hd(entries).message == "line 21"
  end

  test "the counts follow every line in and out, without walking the log" do
    for _ <- 1..390, do: Log.add(:info, "line")
    for _ <- 1..10, do: Log.add(:warn, "warning")

    assert %{held: 400, counts: %{info: 390, warn: 10}} = Log.snapshot()

    # The ring is full now: ten more warnings push ten info lines out of it.
    for _ <- 1..10, do: Log.add(:warn, "warning")

    assert %{held: 400, counts: %{info: 380, warn: 20, error: 0}} = Log.snapshot()
  end

  test "clearing forgets the lines but keeps the service running" do
    Log.add(:info, "something")
    Log.clear()

    assert %{entries: [], held: 0, counts: %{info: 0}} = Log.snapshot()
  end
end
