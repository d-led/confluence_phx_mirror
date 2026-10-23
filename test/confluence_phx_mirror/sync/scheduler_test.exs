defmodule ConfluencePhxMirror.Sync.SchedulerTest do
  @moduledoc """
  The timetable: what one tick enqueues, and the words it uses to say how often
  the mirror pulls.

  A tick is a message the process sends itself, so the test sends it too rather
  than waiting an hour; nothing here is time-dependent beyond that.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Sync.{Scheduler, SnapshotWorker}

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

  defp start_scheduler(interval) do
    name = :"scheduler_for_#{interval}_seconds"
    start_supervised!({Scheduler, [interval: interval, name: name]}, id: name)
  end

  # The GenServer handles its own messages one at a time; asking for its state
  # waits for the tick to be done.
  defp tick(scheduler) do
    send(scheduler, :snapshot)
    :sys.get_state(scheduler)
  end
end
