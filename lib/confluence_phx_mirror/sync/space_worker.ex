defmodule ConfluencePhxMirror.Sync.SpaceWorker do
  @moduledoc """
  Refreshes one space (used by the admin UI and webhooks).

  The outcome is left to `Sync.run/2`, which records a failed run and re-raises
  so that Oban retries; a run that returns is a run that finished.

  A sync already in flight makes this job wait rather than drop the refresh.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 120, keys: [:space_key], states: :incomplete]

  alias ConfluencePhxMirror.Sync

  @default_trigger "a webhook"
  @actor {:system, "space-worker"}

  @impl true
  def perform(%Oban.Job{id: job_id, args: %{"space_key" => space_key} = args}) do
    case Sync.run(:space,
           space_key: space_key,
           job_id: job_id,
           actor: @actor,
           trigger: trigger(args)
         ) do
      {:ok, _run} ->
        :ok

      {:error, :already_running} ->
        Sync.wait_or_stand_down()
    end
  end

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
