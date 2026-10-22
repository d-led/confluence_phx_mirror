defmodule ConfluencePhxMirror.Sync.SnapshotWorker do
  @moduledoc """
  Scheduled full pull of every configured space.

  Uniqueness coalesces overlapping schedules; a snapshot that is already queued
  makes the next tick a no-op instead of stacking work.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3, unique: [period: 300]

  alias ConfluencePhxMirror.Sync

  @impl true
  def perform(%Oban.Job{args: args}) do
    trigger = args["trigger"] || "the sync schedule"

    case Sync.run(:snapshot, actor: {:system, "snapshot-worker"}, trigger: trigger) do
      {:ok, %{status: "failed"} = run} -> {:error, run.error}
      {:ok, _run} -> :ok
    end
  end
end
