defmodule ConfluencePhxMirror.Sync.Scheduler do
  @moduledoc """
  A clock: it enqueues one worker every so often.

  Two of them run in a release, because the mirror has two periodic questions
  for Confluence. A snapshot pull follows `:sync_interval_seconds`
  (`CM_SYNC_INTERVAL_SECONDS`, hourly by default). A verify pass — the one that
  finds the pages Confluence stopped listing — follows
  `:reconcile_interval_seconds` (`CM_RECONCILE_INTERVAL_SECONDS`) and is off
  unless somebody sets it: it asks every space what it holds, which is a
  schedule to choose rather than inherit.

  `0` disables a clock, which is what the demo and test environments use — they
  sync on demand or through webhooks.
  """

  use GenServer

  require Logger

  alias ConfluencePhxMirror.Confluence.Source

  @doc """
  Start a clock.

    * `:worker` — the job one tick enqueues (required)
    * `:interval_key` — the configured interval it reads when none is handed in
      (default `:sync_interval_seconds`)
    * `:interval` — seconds, handed in instead of reading the configuration
    * `:args` — what the job is told besides which schedule asked
    * `:name` — where the clock lives (default `#{inspect(__MODULE__)}`)
  """
  def start_link(opts) do
    clock = clock(opts)
    GenServer.start_link(__MODULE__, clock, name: clock.name)
  end

  # Two clocks of the same module need two child ids, and the registered name is
  # what tells them apart, so it is the id.
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(clock) do
    schedule(clock.interval)
    {:ok, clock}
  end

  @impl true
  def handle_info(:tick, %{interval: interval} = clock) when interval > 0 do
    clock
    |> job()
    |> clock.worker.new()
    |> Oban.insert()
    |> log_enqueue(clock)

    schedule(interval)
    {:noreply, clock}
  end

  # No interval is no timetable: the tick arrived from a schedule this node used
  # to have, so it says nothing and asks for nothing.
  def handle_info(:tick, clock), do: {:noreply, clock}

  defp job(clock), do: Map.put(clock.args, "trigger", "the #{humanise(clock.interval)} schedule")

  defp log_enqueue({:ok, job}, clock),
    do: Logger.debug("scheduled #{name(clock.worker)}", job_id: job.id)

  defp log_enqueue({:error, reason}, clock),
    do: Logger.warning("could not schedule #{name(clock.worker)}", reason: inspect(reason))

  # The worker's own name, without the module path a log line does not need.
  defp name(worker), do: worker |> Module.split() |> List.last()

  defp schedule(interval) when interval > 0,
    do: Process.send_after(self(), :tick, interval * 1000)

  defp schedule(_interval), do: :ok

  # The audit log names the schedule in words: "the hourly schedule" is what an
  # operator would say, and it reads better than a number of seconds.
  defp humanise(3600), do: "hourly"
  defp humanise(86_400), do: "daily"
  defp humanise(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}-minute"
  defp humanise(seconds), do: "#{seconds}-second"

  defp clock(opts) do
    %{
      name: Keyword.get(opts, :name, __MODULE__),
      worker: Keyword.fetch!(opts, :worker),
      args: Keyword.get(opts, :args, %{}),
      interval: interval(opts)
    }
  end

  # An interval handed in is the caller's; otherwise it is the source's own.
  defp interval(opts) do
    case Keyword.get(opts, :interval) do
      nil -> configured_interval(Keyword.get(opts, :interval_key, :sync_interval_seconds))
      seconds -> seconds
    end
  end

  defp configured_interval(key) do
    Application.get_env(:confluence_phx_mirror, Source.source(), []) |> Keyword.get(key, 0)
  end
end
