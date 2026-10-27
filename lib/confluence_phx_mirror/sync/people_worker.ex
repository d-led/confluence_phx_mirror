defmodule ConfluencePhxMirror.Sync.PeopleWorker do
  @moduledoc """
  Re-reads who may read what, without reading any content.

  The identities screen asks this: which groups each identity the mirror knows is
  in, and who the members of every group the content names are. A snapshot
  answers it too, but a snapshot also lists every page of every space, which is
  the wrong price for "somebody joined a group an hour ago".

  The outcome is left to `Sync.run/2`, which records a failed run and re-raises
  so that Oban retries; a run that returns is a run that finished. A sync already
  in flight makes this job wait rather than drop the request.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 120, keys: [], states: :incomplete]

  alias ConfluencePhxMirror.Sync

  @default_trigger "the identities screen"
  @actor {:system, "people-worker"}

  @impl true
  def perform(%Oban.Job{id: job_id, args: args}) do
    case Sync.run(:people,
           job_id: job_id,
           actor: @actor,
           trigger: trigger(args)
         ) do
      {:ok, _run} -> :ok
      {:error, :paused} -> Sync.paused_wait()
      {:error, :already_running} -> Sync.wait_or_stand_down()
    end
  end

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
