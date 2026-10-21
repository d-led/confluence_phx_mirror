defmodule ConfluencePhxMirror.Sync.Scheduler do
  @moduledoc """
  Enqueues periodic snapshot pulls.

  The interval comes from the configured source (`:sync_interval_seconds`,
  `CM_SYNC_INTERVAL_SECONDS`); `0` disables scheduling, which is what the demo
  and test environments use — they sync on demand or through webhooks.
  """

  use GenServer

  require Logger

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Sync.SnapshotWorker

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    interval = interval_seconds()
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:snapshot, %{interval: interval} = state) do
    if interval > 0 do
      %{}
      |> SnapshotWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, job} -> Logger.debug("scheduled snapshot", job_id: job.id)
        {:error, reason} -> Logger.warning("could not schedule snapshot", reason: inspect(reason))
      end

      schedule(interval)
    end

    {:noreply, state}
  end

  defp schedule(interval) when interval > 0,
    do: Process.send_after(self(), :snapshot, interval * 1000)

  defp schedule(_interval), do: :ok

  defp interval_seconds do
    Application.get_env(:confluence_phx_mirror, Source.source(), [])
    |> Keyword.get(:sync_interval_seconds, 0)
  end
end
