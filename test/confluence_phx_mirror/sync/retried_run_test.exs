defmodule ConfluencePhxMirror.Sync.RetriedRunTest do
  @moduledoc """
  A retry is the same sync carrying on, not a second sync.

  Oban runs a failed job again, and a run row is what that job's log lines hang
  from — so a second row for the second attempt reads as a second press to
  whoever looks afterwards, and strands the failing attempt's lines under a run
  nobody opens. That is how "1 error" came to sit above a run whose log held
  none of it.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import Ecto.Query

  alias ConfluencePhxMirror.Confluence.{DemoSource, FailingSource}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{Log, SyncRun}

  @job 4711
  @trigger "the desktop tool"

  test "an attempt that is retried carries on the run it already has" do
    failed = attempt_that_fails()

    assert {:ok, run} = Sync.run(:snapshot, source: DemoSource, job_id: @job, trigger: @trigger)

    assert run.id == failed.id
    assert run.status == "succeeded"
    assert run.stats["attempts"] == 2
    assert [earlier] = run.stats["failed_attempts"]
    assert earlier =~ "unreachable"
    assert runs_of(@job) == 1
  end

  # An Erlang error carries no message worth reading ("Erlang error: :badarg"),
  # so the frames are the only thing that says where it happened — and the log
  # that showed them rolls over.
  test "a failed attempt keeps the frames it failed at" do
    failed = attempt_that_fails()

    assert failed.stats["stacktrace"] =~ "ConfluencePhxMirror.Sync"
  end

  test "the retry's log is the failing attempt's log too" do
    failed = attempt_that_fails()

    assert {:ok, run} = Sync.run(:snapshot, source: DemoSource, job_id: @job, trigger: @trigger)
    assert run.id == failed.id

    lines = run_lines(run)

    assert Enum.any?(lines, &(&1 =~ "sync failed"))
    assert Enum.any?(lines, &(&1 =~ "finished a snapshot sync"))
  end

  test "a run nobody retried says it took one attempt" do
    assert {:ok, run} = Sync.run(:snapshot, source: DemoSource, job_id: @job)

    assert run.stats["attempts"] == 1
    assert run.stats["failed_attempts"] == []
  end

  test "a retry of a different job is a run of its own" do
    attempt_that_fails()

    assert {:ok, run} = Sync.run(:snapshot, source: DemoSource, job_id: @job + 1)

    assert runs_of(@job) == 1
    assert runs_of(@job + 1) == 1
    assert run.status == "succeeded"
  end

  defp attempt_that_fails do
    assert_raise RuntimeError, fn ->
      Sync.run(:snapshot, source: FailingSource, job_id: @job, trigger: @trigger)
    end

    Repo.one(from run in SyncRun, order_by: [desc: run.id], limit: 1)
  end

  defp runs_of(job_id),
    do: Repo.aggregate(from(run in SyncRun, where: run.job_id == ^job_id), :count)

  defp run_lines(run) do
    Log.entries()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.map(& &1.message)
  end
end
