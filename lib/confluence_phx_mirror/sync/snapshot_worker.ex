defmodule ConfluencePhxMirror.Sync.SnapshotWorker do
  @moduledoc """
  The scheduled pull of the whole site.

  It is *incremental* unless asked otherwise: a mirror of a big site re-reads
  only what changed upstream, because re-rendering 400k unchanged pages every
  hour buys nothing. `mode: "snapshot"` asks for a full re-read (a source that
  cannot report changes falls back to one on its own).

  Uniqueness coalesces overlapping schedules; a pull that is already queued
  makes the next tick a no-op instead of stacking work.

  What it does with the outcome is deliberately dull: a run that finishes —
  completely or, when individual pages failed, `partial` — is done, and the next
  tick picks up whatever is missing. A run that *raises* has already been
  recorded as failed by `Sync`; the raise is left to travel, because that is
  what makes Oban retry the job.

  A sync that is already in flight makes this tick a no-op: the run it would
  have started would have copied the same pages (see `Sync.Gate`), and the next
  tick is soon enough. A verify pass holding the lock reads as the same thing —
  one tick lost to a pass of a few minutes, rather than a queue of pulls behind
  it.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Sync

  @default_trigger "the sync schedule"
  @actor {:system, "snapshot-worker"}

  @impl true
  def perform(%Oban.Job{id: job_id, args: args}) do
    case Sync.run(mode(args), job_id: job_id, actor: @actor, trigger: trigger(args)) do
      {:ok, _run} ->
        :ok

      {:error, :paused} ->
        # Nothing is read from the site while the pause is on; the job keeps its
        # place in the queue and comes back after the operator resumes.
        Sync.paused_wait()

      {:error, :already_running} ->
        Logger.info("a sync is already running; this scheduled pull waits for the next tick")
        :ok
    end
  end

  defp mode(%{"mode" => "snapshot"}), do: :snapshot
  defp mode(_args), do: :incremental

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
