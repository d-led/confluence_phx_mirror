defmodule ConfluencePhxMirror.Sync.SpaceWorker do
  @moduledoc "Refreshes one space (used by the admin UI and webhooks)."

  use Oban.Worker, queue: :sync, max_attempts: 3, unique: [period: 120, keys: [:space_key]]

  alias ConfluencePhxMirror.Sync

  @impl true
  def perform(%Oban.Job{args: %{"space_key" => space_key}}) do
    case Sync.run(:space, space_key: space_key, actor: {:system, "space-worker"}) do
      {:ok, %{status: "failed"} = run} -> {:error, run.error}
      {:ok, _run} -> :ok
    end
  end
end
