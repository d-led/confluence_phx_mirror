defmodule ConfluencePhxMirror.Sync.History do
  @moduledoc """
  The sync runs in the database — the whole record, not the eight rows the
  dashboard has room for.

  A mirror keeps a row per run for as long as it keeps anything, and a busy one
  collects a hundred thousand of them: every schedule tick, every page viewed by
  an administrator, every webhook delivery. So the history is read two ways and
  neither of them loads the table:

    * **a window** — `page/1` returns one slice of the newest-first list and the
      total, which is what a client paging through it needs;
    * **a stream** — `batches/0` walks the table in keyset batches (`id > last`),
      oldest first, so a full export costs one batch of memory whatever the
      table's size and holds no transaction open while the download crawls.

  The formats are here rather than in a controller because they are a property
  of the record: CSV for the spreadsheet someone will open, JSON lines for the
  script that reads a hundred thousand of them without holding them either.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Csv
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SyncRun

  @batch 500

  @default_limit 50
  @max_limit 500

  @columns ~w(id source mode scope trigger status started_at finished_at duration_ms
              cancel_requested_at stats error)

  @doc """
  One window of the history, newest first, and how many runs there are.

  `start` is an offset and `limit` is the window's size, the pair the rest of
  the API pages with; `limit/1` is where the ceiling is applied, so a client
  that wants to report the window it got can ask the same question.
  """
  @spec page(keyword()) :: {[SyncRun.t()], non_neg_integer()}
  def page(opts) do
    start = opts |> Keyword.get(:start, 0) |> max(0)
    limit = limit(Keyword.get(opts, :limit, @default_limit))

    runs =
      Repo.all(
        from r in SyncRun,
          order_by: [desc: r.id],
          offset: ^start,
          limit: ^limit
      )

    {runs, count()}
  end

  @doc "How many runs the mirror holds."
  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(SyncRun, :count)

  @doc "The default window size, for the document and for clients that omit it."
  def default_limit, do: @default_limit

  @doc "The largest window a client may ask for."
  def max_limit, do: @max_limit

  @doc "A requested window size, brought inside what the mirror will serve."
  @spec limit(integer() | nil) :: pos_integer()
  def limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  def limit(_limit), do: @default_limit

  @doc """
  The runs, oldest first, in batches — the caller sends each one and forgets it.

  Oldest first because that is the order they happened in, and because a
  download that is interrupted then has the earlier part of the history.
  """
  @spec batches() :: Enumerable.t()
  def batches, do: Stream.unfold(0, &next_batch/1)

  defp next_batch(last_id) do
    runs =
      Repo.all(
        from r in SyncRun,
          where: r.id > ^last_id,
          order_by: [asc: r.id],
          limit: @batch
      )

    case runs do
      [] -> nil
      batch -> {batch, List.last(batch).id}
    end
  end

  @doc "The header line, for the format asked for (CSV only: JSON lines has none)."
  @spec header(:csv | :jsonl) :: iodata()
  def header(:csv), do: Csv.encode_row(@columns) <> "\n"
  def header(:jsonl), do: []

  @doc "One batch, encoded."
  @spec encode(:csv | :jsonl, [SyncRun.t()]) :: iodata()
  def encode(:csv, runs), do: Enum.map(runs, &(Csv.encode_row(row(&1)) <> "\n"))
  def encode(:jsonl, runs), do: Enum.map(runs, &(Jason.encode!(json(&1)) <> "\n"))

  @doc """
  One run as the API shows it: the counters in `stats`, the error in words.

  `durationMs` is null for a run that has not finished — a running one, or one
  whose node went away.
  """
  @spec json(SyncRun.t()) :: map()
  def json(run) do
    %{
      "id" => run.id,
      "source" => run.source,
      "mode" => run.mode,
      "scope" => run.scope,
      "trigger" => SyncRun.trigger(run),
      "status" => run.status,
      "startedAt" => iso(run.started_at),
      "finishedAt" => iso(run.finished_at),
      "durationMs" => SyncRun.duration(run),
      "cancelRequestedAt" => iso(run.cancel_requested_at),
      "stats" => run.stats || %{},
      "error" => run.error
    }
  end

  # The same values as `json/1`, in the file's column order and in the names a
  # spreadsheet reads better: an export is data, not an API.
  defp row(run) do
    [
      run.id,
      run.source,
      run.mode,
      run.scope,
      SyncRun.trigger(run),
      run.status,
      iso(run.started_at),
      iso(run.finished_at),
      SyncRun.duration(run),
      iso(run.cancel_requested_at),
      Jason.encode!(run.stats || %{}),
      run.error
    ]
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
