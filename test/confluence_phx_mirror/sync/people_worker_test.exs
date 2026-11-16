defmodule ConfluencePhxMirror.Sync.PeopleWorkerTest do
  @moduledoc """
  The identities screen's job: ask who may read what, without reading content.

  What the job answers decides what Oban does next, so each answer is a
  behaviour: `:ok` for a run that finished, a snooze for a mirror that is not
  making calls, and a wait — not a dropped request — when a sync already holds
  the mirror.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import Ecto.Query

  alias ConfluencePhxMirror.{Repo, Settings}
  alias ConfluencePhxMirror.Sync.{Gate, PeopleWorker, SyncRun}

  setup do
    Settings.reload()
    # The cache outlives the transaction that held the setting.
    on_exit(fn -> Settings.forget() end)
    :ok
  end

  test "the job reads the people and records the run" do
    assert :ok = perform(%{})

    run = last_run()
    assert run.mode == "people"
    assert run.status in ["succeeded", "partial"]
    assert run.trigger == "the identities screen"
  end

  # An operator's press and the scheduled pass have to read differently in the
  # run log, or every people pass looks like the same one.
  test "the trigger in the job's args is the run's trigger" do
    assert :ok = perform(%{"trigger" => "an operator"})

    assert last_run().trigger == "an operator"
  end

  test "a paused mirror snoozes the job instead of spending an attempt" do
    {:ok, _applied} = Settings.update(%{"sync.paused" => true}, {:system, "test"})
    runs_before = count_runs()

    assert {:snooze, seconds} = perform(%{})
    assert seconds == 300
    assert count_runs() == runs_before
  end

  # A sync already in flight is not an error and not a duplicate: the request
  # waits, which is why the job has three attempts and does not fail here.
  test "a sync already running makes the job wait" do
    test_process = self()

    holder =
      Task.async(fn ->
        Gate.exclusive(fn _owner ->
          send(test_process, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held

    assert {:snooze, 30} = perform(%{})

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
  end

  defp perform(args) do
    PeopleWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})
  end

  defp last_run do
    Repo.one(from r in SyncRun, order_by: [desc: r.id], limit: 1)
  end

  defp count_runs, do: Repo.aggregate(SyncRun, :count)
end
