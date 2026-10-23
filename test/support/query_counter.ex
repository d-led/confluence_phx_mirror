defmodule ConfluencePhxMirror.QueryCounter do
  @moduledoc """
  The SQL a block of code issues, from the repo's telemetry events.

  Counting statements is the cheapest way to see the shape of a read: an N+1
  shows up as a number that grows with the content, and a query that loads a
  whole table shows up in the statement list. Both are invisible in a
  stopwatch, which is why the budgets are pinned on counts and the timings are
  reported next to them.

  The handler runs in the process that issues the query, so a block that
  spawns workers needs each worker counted from its own block.
  """

  @event [:confluence_phx_mirror, :repo, :query]

  @doc "How many statements `fun` issued."
  def count(fun) do
    {_result, entries} = collect(fun)
    length(entries)
  end

  @doc """
  Runs `fun` and returns `{result, entries}`.

  Each entry is `%{sql: binary, millis: float}` — the statement Ecto sent and
  how long the adapter reported it took.
  """
  def collect(fun) do
    test = self()
    handler = {__MODULE__, :collect, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      @event,
      fn _event, measurements, metadata, _config ->
        send(test, {:query, metadata[:query], measurements[:query_time]})
      end,
      nil
    )

    try do
      {fun.(), drain([])}
    after
      :telemetry.detach(handler)
    end
  end

  # Telemetry events are delivered as messages to this process; the queue is
  # empty again by the time the block returns, so a zero timeout is enough.
  defp drain(acc) do
    receive do
      {:query, sql, time} -> drain([%{sql: sql, millis: micros(time) / 1000} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp micros(nil), do: 0
  defp micros(native), do: System.convert_time_unit(native, :native, :microsecond)

  @doc "Totals per statement, most expensive first."
  def summarize(entries) do
    by_sql =
      entries
      |> Enum.group_by(& &1.sql)
      |> Enum.map(fn {sql, rows} ->
        %{
          sql: sql,
          count: length(rows),
          millis: Float.round(Enum.sum(Enum.map(rows, & &1.millis)), 2)
        }
      end)
      |> Enum.sort_by(&{&1.count, &1.millis}, :desc)

    %{
      count: length(entries),
      millis: Float.round(Enum.sum(Enum.map(entries, & &1.millis)), 2),
      by_sql: by_sql
    }
  end

  @doc "The summary as lines of text, for a report."
  def format(summary) do
    header = "    #{summary.count} queries, #{summary.millis} ms in SQL"

    lines =
      Enum.map(summary.by_sql, fn row ->
        "      #{row.count}× #{row.millis} ms  #{one_line(row.sql)}"
      end)

    Enum.join([header | lines], "\n")
  end

  defp one_line(sql) do
    sql
    |> String.replace(~r/\s+/u, " ")
    |> String.slice(0, 160)
  end
end
