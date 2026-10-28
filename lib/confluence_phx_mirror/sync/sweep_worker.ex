defmodule ConfluencePhxMirror.Sync.SweepWorker do
  @moduledoc """
  Re-reads every space, one space per job.

  A snapshot holds the whole site in memory from its first page listing to its
  last detail call. On a site of a hundred thousand pages that is gigabytes,
  and a node with one does not fail the run — it is killed, the run is recorded
  as "the process running this sync stopped before it finished", and the next
  schedule starts the same work over. One space at a time is the same reading
  with a footprint that fits, and a restart then costs one space, not the site.

  The spaces come from the *source*, not from the mirror: a space the mirror has
  never seen has no row to sweep, and finding it is the point.

  What a sweep deliberately does not do is trash. A snapshot trashes the spaces
  its listing no longer names; a sweep cannot tell a space that disappeared
  upstream from one it has not reached yet, so deleting stays with the snapshot.

  `Sync` keeps its own `:snapshot` mode for the command line and for sources
  that cannot report changes; this is the dashboard's "re-read everything".
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.SpaceWorker

  @default_trigger "the sweep"

  # How far apart the space jobs are due. One sync runs at a time, so jobs due
  # sooner than their turn only wake up to find the gate taken and snooze; a
  # minute between them keeps the queue a few rows deep instead of a hundred
  # and fifty, and a slow space is never waited for by more than a handful.
  @spacing_seconds 60

  @impl true
  def perform(%Oban.Job{args: args}) do
    if Settings.sync_paused?() do
      # The sweep is a listing of the site before it is anything else, so a
      # paused mirror does not start one: the job keeps its place in the queue,
      # and the fan-out waits with it instead of queueing a space per space
      # that would only snooze.
      Logger.info("sweep waiting: Confluence calls are paused")
      Sync.paused_wait()
    else
      sweep(trigger(args))
    end
  end

  defp sweep(trigger) do
    # A sweep that could not list the site queued nothing: raise so Oban records
    # the failure instead of a job that "finished" having done no work.
    spaces =
      case Source.source().spaces([]) do
        {:ok, spaces} -> spaces
        {:error, reason} -> raise "could not list the site's spaces: #{inspect(reason)}"
      end

    spaces
    |> Enum.with_index()
    |> Enum.each(fn {space, position} -> queue(space.key, trigger, position) end)

    Logger.info("sweep queued #{length(spaces)} spaces, #{@spacing_seconds}s apart",
      trigger: trigger
    )

    :ok
  end

  defp queue(space_key, trigger, position) do
    args = %{"space_key" => space_key, "trigger" => trigger}

    case Sync.enqueue(SpaceWorker, args, schedule_in: position * @spacing_seconds) do
      {:ok, _job} -> :ok
      {:error, reason} -> raise "could not queue a sync of #{space_key}: #{inspect(reason)}"
    end
  end

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
