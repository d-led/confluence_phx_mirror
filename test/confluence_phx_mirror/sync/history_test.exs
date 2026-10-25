defmodule ConfluencePhxMirror.Sync.HistoryTest do
  @moduledoc """
  The run history is read two ways: a window with the total beside it, and a
  stream that never holds more than one batch. Both are shown here against the
  runs they are supposed to carry, and both files are read back the way a
  spreadsheet and a script would read them.
  """
  use ConfluencePhxMirror.DataCase, async: true

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.{History, SyncRun}

  describe "a window of the history" do
    test "is newest first, with the total beside it" do
      older = run_fixture(started_at: ~U[2026-10-01 10:00:00Z])
      newer = run_fixture(started_at: ~U[2026-10-02 10:00:00Z])

      assert {[first, second], 2} = History.page([])
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "moves by the offset the caller asks for" do
      _older = run_fixture(started_at: ~U[2026-10-01 10:00:00Z])
      newer = run_fixture(started_at: ~U[2026-10-02 10:00:00Z])

      assert {[second_page], 2} = History.page(start: 1, limit: 1)
      refute second_page.id == newer.id
    end

    test "a window larger than the mirror serves is brought down to the largest it does" do
      assert History.limit(10_000) == History.max_limit()
      assert History.limit(nil) == History.default_limit()
      assert History.limit(0) == History.default_limit()
    end
  end

  describe "the stream" do
    test "crosses a batch boundary without losing or repeating a run" do
      insert_runs(501)

      ids =
        History.batches()
        |> Enum.flat_map(fn batch -> Enum.map(batch, & &1.id) end)

      assert length(ids) == 501
      assert ids == Enum.sort(ids), "oldest first: the history in the order it happened"
    end
  end

  describe "the files" do
    test "CSV names every column once, in the order the rows are written" do
      run = run_fixture(stats: %{"pages" => 3, "changed" => 2})
      [header, row] = csv(run)

      assert header ==
               "id,source,mode,scope,status,started_at,finished_at,duration_ms,cancel_requested_at,stats,error"

      assert String.starts_with?(row, "#{run.id},confluence-http,webhook,page 1002,succeeded,")
    end

    test "a message with a comma stays one cell" do
      run = run_fixture(error: "the page said no, twice")
      [_header, row] = csv(run)

      assert row =~ ~s("the page said no, twice")
    end

    test "JSON lines is one run per line, with the counters as an object" do
      run = run_fixture(stats: %{"pages" => 3, "changed" => 2})

      assert [json] = lines(History.encode(:jsonl, [run]))
      assert json["id"] == run.id
      assert json["stats"] == %{"pages" => 3, "changed" => 2}
      assert json["startedAt"] == "2026-10-01T10:00:00Z"
      assert json["durationMs"] == 60_000
    end
  end

  defp csv(run) do
    (History.header(:csv) <> IO.iodata_to_binary(History.encode(:csv, [run])))
    |> String.split("\n", trim: true)
  end

  defp lines(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # A run that finished a minute after it started, in the shape the sync writes
  # them: one page asked for by a page view.
  defp run_fixture(attrs) do
    defaults = [
      source: "confluence-http",
      mode: "webhook",
      scope: "page 1002",
      status: "succeeded",
      started_at: ~U[2026-10-01 10:00:00Z],
      finished_at: ~U[2026-10-01 10:01:00Z]
    ]

    %SyncRun{}
    |> SyncRun.changeset(Map.new(Keyword.merge(defaults, attrs)))
    |> Repo.insert!()
  end

  defp insert_runs(count) do
    started = ~U[2026-10-01 10:00:00Z]

    rows =
      for index <- 1..count do
        %{
          source: "confluence-http",
          mode: "incremental",
          scope: "the site",
          status: "succeeded",
          started_at: started,
          inserted_at: started,
          updated_at: started
        }
        |> Map.put(:id, index)
      end

    Repo.insert_all(SyncRun, rows)
  end
end
