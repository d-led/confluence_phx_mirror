defmodule ConfluencePhxMirror.Sync.SnapshotWorkerTest do
  @moduledoc """
  The scheduled pull: what the arguments mean, and what the worker does with the
  outcome.

  A source that lists nothing keeps these tests about the worker — an empty
  listing is still a successful run, and the demo snapshot is exercised by
  `SyncTest`.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Confluence.{EmptyListingSource, FailingSource}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.{SnapshotWorker, SyncRun}
  alias ConfluencePhxMirror.TestConfig

  setup do
    configure_source(EmptyListingSource)
    :ok
  end

  test "the schedule pulls only what changed" do
    assert :ok = perform_job(SnapshotWorker, %{})

    assert last_run().mode == "incremental"
    assert last_run().status == "succeeded"
  end

  test "mode: snapshot asks for a full re-read" do
    assert :ok = perform_job(SnapshotWorker, %{"mode" => "snapshot"})

    assert last_run().mode == "snapshot"
  end

  test "an unknown mode is an incremental pull, not a full one" do
    assert :ok = perform_job(SnapshotWorker, %{"mode" => "everything"})

    assert last_run().mode == "incremental"
  end

  test "the trigger names the asker in the audit trail" do
    assert :ok = perform_job(SnapshotWorker, %{"trigger" => "an administrator"})

    assert finished_entry(last_run()).metadata["trigger"] == "an administrator"
  end

  test "without a trigger the audit says it was the schedule" do
    assert :ok = perform_job(SnapshotWorker, %{})

    assert finished_entry(last_run()).metadata["trigger"] == "the sync schedule"
  end

  test "a source that cannot be reached fails the run, and raises for Oban to retry" do
    configure_source(FailingSource)

    error = assert_raise RuntimeError, fn -> perform_job(SnapshotWorker, %{}) end
    assert error.message =~ ":unreachable"

    assert last_run().status == "failed"
    assert last_run().error =~ "unreachable"
  end

  defp configure_source(source), do: TestConfig.put(:source, source)

  defp last_run do
    Repo.one(from run in SyncRun, order_by: [desc: run.id], limit: 1)
  end

  defp finished_entry(run) do
    Repo.one(
      from event in Event,
        where: event.action == "sync.finished" and event.entity_id == ^to_string(run.id),
        order_by: [desc: event.id],
        limit: 1
    )
  end
end
