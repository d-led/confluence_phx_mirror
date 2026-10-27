defmodule ConfluencePhxMirror.Sync.SchedulerTest do
  @moduledoc """
  The timetable: what one tick enqueues, and the words it uses to say how often
  the mirror pulls.

  A tick is a message the process sends itself, so the test sends it too rather
  than waiting an hour; nothing here is time-dependent beyond that.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync.{ReconcileWorker, Scheduler, SnapshotWorker}

  @actor {:system, "scheduler test"}

  test "an hourly tick asks for an incremental pull, and says it was the schedule" do
    tick(start_scheduler(3600))

    assert_enqueued(
      worker: SnapshotWorker,
      args: %{"mode" => "incremental", "trigger" => "the hourly schedule"}
    )
  end

  for {interval, wording} <- [{86_400, "daily"}, {900, "15-minute"}, {90, "90-second"}] do
    test "#{interval} seconds is the #{wording} schedule" do
      tick(start_scheduler(unquote(interval)))

      assert_enqueued(
        worker: SnapshotWorker,
        args: %{"trigger" => "the #{unquote(wording)} schedule"}
      )
    end
  end

  test "a scheduler with no interval leaves the mirror alone" do
    tick(start_scheduler(0))

    refute_enqueued(worker: SnapshotWorker)
  end

  test "the same clock runs the missing-pages check when it is told to" do
    name = :reconcile_clock

    start_supervised!(
      {Scheduler,
       interval: 86_400,
       interval_key: :reconcile_interval_seconds,
       worker: ReconcileWorker,
       name: name},
      id: name
    )

    tick(name)

    assert_enqueued(worker: ReconcileWorker, args: %{"trigger" => "the daily schedule"})
  end

  test "a clock with nothing decided anywhere leaves the mirror alone" do
    # The suite's demo source sets `sync_interval_seconds: 0` and says nothing
    # about the check, so this clock reads 0 and its tick asks for nothing.
    name = :quiet_clock

    start_supervised!(
      {Scheduler, interval_key: :reconcile_interval_seconds, worker: ReconcileWorker, name: name},
      id: name
    )

    tick(name)

    refute_enqueued(worker: ReconcileWorker)
  end

  test "a cadence an administrator stored is the one the next tick uses" do
    {:ok, _applied} = Settings.update(%{"sync.interval_seconds" => "900"}, @actor)
    on_exit(fn -> Settings.clear(["sync.interval_seconds"], @actor) end)

    name = :stored_clock

    start_supervised!(
      {Scheduler,
       worker: SnapshotWorker,
       args: %{"mode" => "incremental", "scope" => "the whole site, what changed"},
       name: name},
      id: name
    )

    tick(name)

    assert_enqueued(
      worker: SnapshotWorker,
      args: %{"trigger" => "the 15-minute schedule"}
    )
  end

  defp start_scheduler(interval) do
    name = :"scheduler_for_#{interval}_seconds"

    start_supervised!(
      {Scheduler,
       interval: interval,
       interval_key: :sync_interval_seconds,
       worker: SnapshotWorker,
       args: %{"mode" => "incremental", "scope" => "the whole site, what changed"},
       name: name},
      id: name
    )
  end

  # The GenServer handles its own messages one at a time; asking for its state
  # waits for the tick to be done.
  defp tick(scheduler) do
    send(scheduler, :tick)
    :sys.get_state(scheduler)
  end
end
