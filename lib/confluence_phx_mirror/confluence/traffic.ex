defmodule ConfluencePhxMirror.Confluence.Traffic do
  @moduledoc """
  What a sync's calls to Confluence cost, counted as they happen.

  Every HTTP attempt is one line in the sync log; that stream is the detail.
  This module keeps the totals — calls, retries, the time the client-side rate
  limiter made a call wait, bytes and failures — so a run can end with a summary
  an operator can act on without scrolling.

  The counters live in a public ETS table and move with `:ets.update_counter/4`,
  so recording a call is one BIF and never queues behind a process. The table is
  created by this module's process at boot, so the totals outlive the worker
  that filled them — the admin page reads them after the run has finished.
  `reset/0` is called when a run starts; a caller that never resets (the probe,
  the seed task) simply keeps counting.

  The account is per node, not per run: two syncs running at the same time share
  it, exactly as they share the sync log's current run id. Scheduled pulls
  coalesce (the worker is unique), so in practice a node runs one at a time.
  """

  use GenServer

  @table __MODULE__

  @type status :: integer()

  @type summary :: %{
          requests: non_neg_integer(),
          duration_ms: non_neg_integer(),
          avg_ms: non_neg_integer(),
          bytes: non_neg_integer(),
          retries: non_neg_integer(),
          throttled: non_neg_integer(),
          waited_ms: non_neg_integer(),
          failed: non_neg_integer(),
          statuses: %{status() => pos_integer()},
          slowest: {non_neg_integer(), String.t()} | nil
        }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, create_table()}

  @doc "Starts a fresh account. Called when a sync run begins."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(table())
    :ok
  end

  @doc "Records one attempt: the status it got, how long it took and how many bytes came back."
  @spec request(status(), non_neg_integer(), non_neg_integer()) :: :ok
  def request(status, duration_ms, bytes) do
    add(:requests, 1)
    add(:duration_ms, duration_ms)
    add(:bytes, bytes)
    add({:status, status}, 1)
  end

  @doc "Records that an attempt is being repeated after a retryable answer."
  @spec retry() :: :ok
  def retry, do: add(:retries, 1)

  @doc "Records time a call spent waiting for the client-side rate limiter."
  @spec throttled(non_neg_integer()) :: :ok
  def throttled(0), do: :ok

  def throttled(waited_ms) do
    add(:throttled, 1)
    add(:waited_ms, waited_ms)
  end

  @doc "Records a call that was still failing after its last attempt."
  @spec failed(status() | atom()) :: :ok
  def failed(label) do
    add(:failed, 1)
    add({:failure, label}, 1)
  end

  @doc "Keeps the slowest call seen so far, which is the one worth looking at first."
  @spec slowest(String.t(), non_neg_integer()) :: :ok
  def slowest(label, duration_ms) do
    case :ets.lookup(table(), :slowest) do
      [{:slowest, {known, _}}] when known >= duration_ms -> :ok
      _ -> :ets.insert(table(), {:slowest, {duration_ms, label}})
    end

    :ok
  end

  @doc "The totals so far, in the shape `describe/1` reads."
  @spec summary() :: summary()
  def summary do
    requests = get(:requests)
    duration_ms = get(:duration_ms)

    %{
      requests: requests,
      duration_ms: duration_ms,
      avg_ms: if(requests == 0, do: 0, else: round(duration_ms / requests)),
      bytes: get(:bytes),
      retries: get(:retries),
      throttled: get(:throttled),
      waited_ms: get(:waited_ms),
      failed: get(:failed),
      statuses: statuses(),
      slowest: slowest()
    }
  end

  @doc """
  The summary as a sentence: what the calls cost, in the numbers that matter.

      "1,234 calls · 45.8 MB · avg 41 ms · 31 retried · 380 throttled (12.5 s waited) · 2 failed"
  """
  @spec describe(summary()) :: String.t()
  def describe(summary) do
    [
      "#{number(summary.requests)} #{pluralize(summary.requests, "call")}",
      human_size(summary.bytes),
      "avg #{summary.avg_ms} ms",
      retried(summary.retries),
      throttled(summary.throttled, summary.waited_ms),
      failed_count(summary.failed),
      slowest_call(summary.slowest)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  The answers the site gave, e.g. `"200×1,201 429×31 503×2"`.

  Every attempt counts, including the ones that were retried: an `429` next to a
  handful of `200`s is throttling at work, which is exactly the number an
  operator wants when a run felt slow.
  """
  @spec answers(summary()) :: String.t()
  def answers(%{statuses: statuses}) do
    statuses
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(" ", fn {status, count} -> "#{status}×#{number(count)}" end)
  end

  defp retried(0), do: nil
  defp retried(count), do: "#{number(count)} retried"

  defp throttled(0, _waited_ms), do: nil

  defp throttled(count, waited_ms),
    do: "#{number(count)} throttled (#{duration(waited_ms)} waited)"

  defp failed_count(0), do: nil
  defp failed_count(count), do: "#{number(count)} failed"

  defp slowest_call(nil), do: nil
  defp slowest_call({duration_ms, label}), do: "slowest #{label} #{duration_ms} ms"

  # Milliseconds for a wait, seconds once it is long enough to feel like a pause.
  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  defp human_size(bytes) when bytes < 1_024, do: "#{bytes} B"

  defp human_size(bytes) do
    units = ~w(KB MB GB TB)
    scale = bytes |> :math.log10() |> Kernel./(3) |> trunc()
    unit = Enum.at(units, min(scale - 1, length(units) - 1))
    "#{Float.round(bytes / :math.pow(1_024, scale), 1)} #{unit}"
  end

  # Thousands separators: a six-figure call count is unreadable otherwise.
  defp number(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.codepoints()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp pluralize(1, noun), do: noun
  defp pluralize(_count, noun), do: noun <> "s"

  defp statuses do
    table()
    |> :ets.select([{{{:status, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new()
  end

  defp slowest do
    case :ets.lookup(table(), :slowest) do
      [{:slowest, slowest}] -> slowest
      [] -> nil
    end
  end

  defp get(key) do
    case :ets.lookup(table(), key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  # `:ets.update_counter/4` answers the new count, which no caller wants: these
  # counters are for a screen to read, not for control flow.
  defp add(key, amount) do
    _count = :ets.update_counter(table(), key, amount, {key, 0})
    :ok
  end

  # Created at boot by `init/1`; the fallback keeps the module usable where the
  # application is not running (a plain `elixir -e`, a test of this module).
  defp table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _table -> @table
    end
  end

  defp create_table do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])
  rescue
    ArgumentError -> @table
  end
end
