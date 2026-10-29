defmodule ConfluencePhxMirror.Sync.ReconcileWorkerTest do
  @moduledoc """
  A verify pass is a run against the site, so it takes the sync lock like one.

  It waits while a sync is reading the site — a pass must not mark pages absent
  from a mirror that is still being written — and it holds the lock for as long
  as it asks, which is what lets the boot sweep tell a pass whose node died from
  one that is still working (`SyncGateTest`).
  """

  use ConfluencePhxMirror.DataCase, async: true

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
