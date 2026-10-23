defmodule ConfluencePhxMirror.Sync.SpaceWorkerTest do
  @moduledoc """
  The admin's "refresh this space" button and the space webhooks both end up
  here: one space re-read, and an audit trail that says which of them asked.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.{SpaceWorker, SyncRun}

  test "a space is re-read on its own" do
    assert :ok = perform_job(SpaceWorker, %{"space_key" => "PROD"})

    assert last_run().status == "succeeded"
    assert started_entry(last_run()).metadata["mode"] == "space"
    assert {:ok, _page} = Mirror.find_page(2001)
  end

  test "the trigger names the admin who asked in the audit trail" do
    assert :ok =
             perform_job(SpaceWorker, %{
               "space_key" => "PROD",
               "trigger" => "an administrator"
             })

    assert finished_entry(last_run()).metadata["trigger"] == "an administrator"
  end

  test "without a trigger the audit names a webhook" do
    assert :ok = perform_job(SpaceWorker, %{"space_key" => "PROD"})

    assert finished_entry(last_run()).metadata["trigger"] == "a webhook"
  end

  defp last_run do
    Repo.one(from run in SyncRun, order_by: [desc: run.id], limit: 1)
  end

  defp started_entry(run) do
    Repo.one(
      from event in Event,
        where: event.action == "sync.started" and event.entity_id == ^to_string(run.id),
        order_by: [desc: event.id],
        limit: 1
    )
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
