defmodule ConfluencePhxMirror.Measure do
  @moduledoc """
  Timing a request the way a reader feels it: whole calls, median and worst.

  A single measurement is noise — the first request warms the plan cache, the
  machine is doing something else — so a figure here is the median of several
  runs, with the worst one next to it. Nothing is asserted on wall time in the
  scale suite: the numbers are reported, and the query counts are what a
  regression breaks.
  """

  @doc """
  Runs `fun` `runs` times and reports milliseconds.

  The first run is thrown away: it pays for the connections, the query plans and
  the code paths that get loaded lazily, which is not what a reader repeats.
  """
  def timings(fun, runs \\ 11) do
    {_millis, result} = time(fun)
    times = for _ <- 1..runs, do: elem(time(fun), 0)

    %{
      result: result,
      runs: runs,
      median_ms: Float.round(Enum.at(Enum.sort(times), div(runs, 2)), 2),
      max_ms: Float.round(Enum.max(times), 2)
    }
  end

  @doc "How long `fun` took, in milliseconds, and what it returned."
  def time(fun) do
    {micros, result} = :timer.tc(fun)
    {micros / 1000, result}
  end

  @doc "Size of a response body in kilobytes, rounded."
  def kb(body) when is_binary(body), do: Float.round(byte_size(body) / 1024, 1)
end
