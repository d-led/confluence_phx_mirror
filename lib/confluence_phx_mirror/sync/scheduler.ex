defmodule ConfluencePhxMirror.Sync.Scheduler do
  @moduledoc """
  Enqueues periodic snapshot pulls.

  The interval comes from the configured source (`:sync_interval_seconds`,
  `CM_SYNC_INTERVAL_SECONDS`) unless the caller hands one in; `0` disables
  scheduling, which is what the demo and test environments use — they sync on
  demand or through webhooks.
  """

  use GenServer

  require Logger

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Sync.SnapshotWorker

  def start_link(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :interval, &interval_seconds/0)

    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = Keyword.fetch!(opts, :interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:snapshot, %{interval: interval} = state) when interval > 0 do
    %{"trigger" => "the #{humanise(interval)} schedule", "mode" => "incremental"}
    |> SnapshotWorker.new()
    |> Oban.insert()
    |> log_enqueue()

    schedule(interval)
    {:noreply, state}
  end

  # No interval is no timetable: the tick arrived from a schedule this node used
  # to have, so it says nothing and asks for nothing.
  def handle_info(:snapshot, state), do: {:noreply, state}

  defp log_enqueue({:ok, job}), do: Logger.debug("scheduled snapshot", job_id: job.id)

  defp log_enqueue({:error, reason}),
    do: Logger.warning("could not schedule snapshot", reason: inspect(reason))

  defp schedule(interval) when interval > 0,
    do: Process.send_after(self(), :snapshot, interval * 1000)

  defp schedule(_interval), do: :ok

  # The audit log names the schedule in words: "the hourly schedule" is what an
  # operator would say, and it reads better than a number of seconds.
  defp humanise(3600), do: "hourly"
  defp humanise(86_400), do: "daily"
  defp humanise(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}-minute"
  defp humanise(seconds), do: "#{seconds}-second"

  defp interval_seconds do
    Application.get_env(:confluence_phx_mirror, Source.source(), [])
    |> Keyword.get(:sync_interval_seconds, 0)
  end
end
