defmodule ConfluencePhxMirror.Sync.SnapshotWorker do
  @moduledoc """
  The scheduled pull of the whole site.

  It is *incremental* unless asked otherwise: a mirror of a big site re-reads
  only what changed upstream, because re-rendering 400k unchanged pages every
  hour buys nothing. `mode: "snapshot"` asks for a full re-read (a source that
  cannot report changes falls back to one on its own).

  Uniqueness coalesces overlapping schedules; a pull that is already queued
  makes the next tick a no-op instead of stacking work.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3, unique: [period: 300]

  alias ConfluencePhxMirror.Sync

  @impl true
  def perform(%Oban.Job{args: args}) do
    trigger = args["trigger"] || "the sync schedule"
    mode = if args["mode"] == "snapshot", do: :snapshot, else: :incremental

    case Sync.run(mode, actor: {:system, "snapshot-worker"}, trigger: trigger) do
      {:ok, %{status: "failed"} = run} -> {:error, run.error}
      {:ok, _run} -> :ok
    end
  end
end
