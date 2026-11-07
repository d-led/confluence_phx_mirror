defmodule ConfluencePhxMirror.Sync.ReconcileWorkerTest do
  @moduledoc """
  A verify pass is a run against the site, so it takes the sync lock like one.

  It waits while a sync is reading the site — a pass must not mark pages absent
  from a mirror that is still being written — and it holds the lock for as long
  as it asks, which is what lets the boot sweep tell a pass whose node died from
  one that is still working (`SyncGateTest`).

  The lock is one row for the whole database, so this file cannot run beside a
  test that starts a run: two claims of the same row meet on its unique index and
  the second is answered `{:error, :already_running}`, which is the correct
  answer for the code and the wrong one for the assertion. Hence `async: false` —
  a test of a database-wide lock is a test that needs the database to itself.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Sync.{Gate, ReconcileRun, ReconcileWorker}

  test "waits for its turn while a sync holds the lock" do
    {:ok, :held} =
      Gate.exclusive(fn _owner ->
        assert {:snooze, 60} = perform_job(ReconcileWorker, %{"trigger" => "a test"})
        :held
      end)

    assert ReconcileRun.history() == [], "a pass that never got its turn recorded nothing"
  end

  test "asks the site when the lock is free" do
    assert :ok = perform_job(ReconcileWorker, %{"trigger" => "a test"})

    assert %ReconcileRun{trigger: "a test"} = ReconcileRun.last_finished()
  end
end
