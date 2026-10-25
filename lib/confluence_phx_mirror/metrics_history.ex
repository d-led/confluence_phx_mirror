defmodule ConfluencePhxMirror.MetricsHistory do
  @moduledoc """
  The last couple of hours of the catalogue metrics, in memory, for the runtime
  dashboard's charts.

  LiveDashboard draws a metric from the moment the browser page opened unless it
  is handed a history (`metrics_history: {__MODULE__, :metrics_history, []}`).
  For a gauge that moves once per import that is a blank chart, which is why
  this exists: one telemetry handler records every `confluence_mirror.catalogue`
  event into an ordered ETS table, and `metrics_history/1` answers the callback
  with the points it has.

  Per node and in memory on purpose: two replicas each keep their own, the table
  belongs to a supervised process, and a restart starts a new chart rather than
  showing numbers nobody can vouch for. `@points` at the poller's ten-second
  cadence is two hours.
  """

  use GenServer

  @table __MODULE__
  @points 720
  @handler {__MODULE__, :recorder}
  @event [:confluence_mirror, :catalogue]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  One metric's recorded points, oldest first — LiveDashboard's history callback.

  A metric this store never recorded (the VM's, Phoenix's) answers with no
  history, and its chart starts when the browser page opens, which is what the
  dashboard does without a store at all.
  """
  def metrics_history(%{name: name}) do
    name
    |> List.wrap()
    |> Enum.join(".")
    |> points()
  end

  @doc false
  def record(_event, measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:record, measurements})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :named_table, :public, read_concurrency: true])
    :telemetry.attach(@handler, @event, &__MODULE__.record/4, nil)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, measurements}, state) do
    now = System.system_time(:microsecond)

    for {measurement, value} <- measurements, is_number(value) do
      series = Enum.join(@event ++ [measurement], ".")
      :ets.insert(@table, {{series, now}, value})
      trim(series)
    end

    {:noreply, state}
  end

  # One series is a range of an ordered set keyed `{series, time}`, so the match
  # spec's bound prefix is what makes this a seek rather than a scan. The body
  # asks for a tuple — a list body is read as several result expressions, and a
  # tuple whose first element is a string is read as a function call.
  defp points(series) do
    for {time, value} <-
          :ets.select(@table, [{{{series, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]) do
      %{label: nil, measurement: value, time: time}
    end
  end

  # Only the newest @points are kept: a long-lived node must not grow a table
  # with the lifetime of the machine.
  defp trim(series) do
    excess = :ets.select_count(@table, [{{{series, :_}, :_}, [], [true]}]) - @points

    if excess > 0 do
      {times, _more} =
        :ets.select(@table, [{{{series, :"$1"}, :_}, [], [:"$1"]}], excess)

      Enum.each(times, &:ets.delete(@table, {series, &1}))
    end
  end
end
