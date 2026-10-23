defmodule ConfluencePhxMirror.Sync.SpaceWorker do
  @moduledoc """
  Refreshes one space (used by the admin UI and webhooks).

  The outcome is left to `Sync.run/2`, which records a failed run and re-raises
  so that Oban retries; a run that returns is a run that finished.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3, unique: [period: 120, keys: [:space_key]]

  alias ConfluencePhxMirror.Sync

  @default_trigger "a webhook"
  @actor {:system, "space-worker"}

  @impl true
  def perform(%Oban.Job{args: %{"space_key" => space_key} = args}) do
    {:ok, _run} =
      Sync.run(:space,
        space_key: space_key,
        actor: @actor,
        trigger: trigger(args)
      )

    :ok
  end

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
