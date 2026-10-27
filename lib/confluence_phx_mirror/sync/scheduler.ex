defmodule ConfluencePhxMirror.Sync.Scheduler do
  @moduledoc """
  A clock: it enqueues one worker every so often.

  Two of them run in a release, because the mirror has two periodic questions
  for Confluence. A snapshot pull follows the *sync interval*
  (`CM_SYNC_INTERVAL_SECONDS`, hourly by default). A verify pass — the one that
  finds the pages Confluence stopped listing — follows the *missing-pages
  interval* (`CM_RECONCILE_INTERVAL_SECONDS`) and is off unless somebody sets
  it: it asks every space what it holds, which is a schedule to choose rather
  than inherit.

  Both intervals are settings (`ConfluencePhxMirror.Settings`), read on every
  tick rather than at boot: a mirror pulls more or less often because somebody
  said so on the settings screen, not because a release was cut. A change
  therefore applies from the tick after the one in flight.

  `0` disables a clock, which is what the demo and test environments use — they
  sync on demand or through webhooks. A disabled clock keeps a slow heartbeat,
  so switching it back on is noticed within a minute.
  """

  use GenServer

  require Logger

  alias ConfluencePhxMirror.Settings

  # How often a switched-off schedule looks again, so switching it back on does
  # not wait for a release.
  @off_heartbeat 60_000

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
    schedule(interval(clock))
    {:ok, clock}
  end

  # The cadence is read on every tick, not once at boot: an administrator changes
  # it on the settings screen, and a mirror should not need a release to pull
  # more or less often. A schedule that is switched off keeps a slow heartbeat,
  # so switching it back on is noticed within a minute rather than at the next
  # reboot.
  @impl true
  def handle_info(:tick, clock) do
    case interval(clock) do
      seconds when seconds > 0 ->
        clock
        |> job(seconds)
        |> clock.worker.new()
        |> Oban.insert()
        |> log_enqueue(clock)

        schedule(seconds)

      _off ->
        schedule(@off_heartbeat)
    end

    {:noreply, clock}
  end

  defp job(clock, seconds),
    do: Map.put(clock.args, "trigger", "the #{humanise(seconds)} schedule")

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
      interval: Keyword.get(opts, :interval),
      interval_key: Keyword.get(opts, :interval_key, :sync_interval_seconds)
    }
  end

  # A cadence the caller handed in is the caller's, forever (a test's, or a
  # deployment's); otherwise it is read afresh, so an administrator's change
  # takes effect at the next tick without a restart.
  defp interval(%{interval: seconds}) when is_integer(seconds), do: seconds
  defp interval(%{interval_key: key}), do: configured_interval(key)

  # The two schedules this mirror has, by the key that configures them. Naming
  # them here rather than reading the source's config keeps the clock's cadence
  # in the same place as the rest of what an administrator decides.
  defp configured_interval(:sync_interval_seconds), do: Settings.sync_interval_seconds()

  defp configured_interval(:reconcile_interval_seconds),
    do: Settings.reconcile_interval_seconds()
end
