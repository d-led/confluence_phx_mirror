defmodule ConfluencePhxMirror.Sync.StartupPull do
  @moduledoc """
  Fills a mirror that has never been filled.

  A release has no seeds: `/app/bin/migrate` leaves an empty database, and a
  fresh container would then serve an empty mirror until somebody pressed *Sync
  now* or a clock reached its first tick — an hour away, and never at all on a
  machine that stops when nobody is reading. `CM_BOOTSTRAP_SYNC=true` asks for
  one snapshot instead, the first time a node starts against an empty mirror.

  It is a question about the mirror, not a schedule: a database that already
  holds a space is left alone, and so is a paused mirror. The job is the
  ordinary `SnapshotWorker`, so the run is gated, recorded and visible like any
  other — and because that worker is unique on its queue, a restart while the
  pull is still queued coalesces instead of stacking a second one.
  """

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.SnapshotWorker

  @trigger "the first start of an empty mirror"

  @typedoc "The boot decision, said once in the log."
  @type outcome ::
          :off | :paused | :not_empty | {:ok, Oban.Job.t()} | {:error, term()}

  @doc """
  Queues one snapshot when the mirror is empty and the deployment asked for it.

  Called once from `ConfluencePhxMirror.Application.start/2`, after the
  supervisor is up: `Settings` is loaded by then, so the pause is the one an
  operator chose rather than a default.
  """
  @spec pull() :: outcome()
  def pull do
    cond do
      not enabled?() -> :off
      Settings.sync_paused?() -> :paused
      Mirror.count_spaces() > 0 -> :not_empty
      true -> enqueue()
    end
  end

  defp enabled? do
    Application.get_env(:confluence_phx_mirror, :bootstrap_sync, false) == true
  end

  defp enqueue do
    Sync.enqueue(SnapshotWorker, %{"mode" => "snapshot", "trigger" => @trigger})
  end
end
