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

  use Oban.Worker, queue: :sync, max_attempts: 1, unique: [period: 600]

  require Logger

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Sync.SpaceWorker

  @default_trigger "the sweep"

  @impl true
  def perform(%Oban.Job{args: args}) do
    trigger = trigger(args)

    # A sweep that could not list the site queued nothing: raise so Oban records
    # the failure instead of a job that "finished" having done no work.
    spaces =
      case Source.source().spaces([]) do
        {:ok, spaces} -> spaces
        {:error, reason} -> raise "could not list the site's spaces: #{inspect(reason)}"
      end

    Enum.each(spaces, &queue(&1.key, trigger))
    Logger.info("sweep queued #{length(spaces)} spaces", trigger: trigger)
    :ok
  end

  defp queue(space_key, trigger) do
    case %{"space_key" => space_key, "trigger" => trigger}
         |> SpaceWorker.new()
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> raise "could not queue a sync of #{space_key}: #{inspect(reason)}"
    end
  end

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
