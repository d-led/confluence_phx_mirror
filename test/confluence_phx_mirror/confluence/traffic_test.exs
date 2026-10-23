defmodule ConfluencePhxMirror.Confluence.TrafficTest do
  @moduledoc """
  The counters behind the sync log's call summary: what a run's calls cost,
  counted per attempt, and the sentence that reports them.
  """
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.Traffic

  setup do
    Traffic.reset()
    on_exit(&Traffic.reset/0)
    :ok
  end

  test "counts calls, the answers they got, their bytes and their latency" do
    Traffic.request(200, 40, 1_024)
    Traffic.request(429, 10, 0)
    Traffic.request(200, 20, 2_048)

    summary = Traffic.summary()

    assert summary.requests == 3
    assert summary.bytes == 3_072
    assert summary.avg_ms == 23
    assert summary.statuses == %{200 => 2, 429 => 1}
    assert summary.failed == 0
  end

  test "counts retries and the time calls spent waiting for the limiter" do
    Traffic.retry()
    Traffic.throttled(120)
    Traffic.throttled(80)
    Traffic.throttled(0)

    summary = Traffic.summary()

    assert summary.retries == 1
    assert summary.throttled == 2
    assert summary.waited_ms == 200
  end

  test "counts a call that was still failing after its last attempt" do
    Traffic.request(503, 5, 0)
    Traffic.failed(503)

    assert Traffic.summary().failed == 1
  end

  test "keeps the slowest call, which is the one worth looking at first" do
    Traffic.slowest("GET /content", 40)
    Traffic.slowest("GET /space", 120)
    Traffic.slowest("GET /content", 90)

    assert Traffic.summary().slowest == {120, "GET /space"}
  end

  test "a quiet account has a zero average rather than a division by zero" do
    assert %{requests: 0, avg_ms: 0, statuses: %{}, slowest: nil} = Traffic.summary()
  end

  describe "describe/1" do
    test "says what the calls cost, in the numbers that matter" do
      summary = %{
        requests: 1_234,
        duration_ms: 50_594,
        avg_ms: 41,
        bytes: 48_000_000,
        retries: 31,
        throttled: 380,
        waited_ms: 12_500,
        failed: 2,
        statuses: %{200 => 1_201, 429 => 31, 503 => 2},
        slowest: {1_200, "GET /content"}
      }

      assert Traffic.describe(summary) ==
               "1,234 calls · 45.8 MB · avg 41 ms · 31 retried · " <>
                 "380 throttled (12.5 s waited) · 2 failed · slowest GET /content 1200 ms"
    end

    test "leaves out what did not happen" do
      summary = %{
        requests: 3,
        duration_ms: 36,
        avg_ms: 12,
        bytes: 512,
        retries: 0,
        throttled: 0,
        waited_ms: 0,
        failed: 0,
        statuses: %{200 => 3},
        slowest: nil
      }

      assert Traffic.describe(summary) == "3 calls · 512 B · avg 12 ms"
    end
  end

  test "answers/1 lists every status, including the ones that were retried" do
    Traffic.request(200, 1, 0)
    Traffic.request(200, 1, 0)
    Traffic.request(429, 1, 0)

    assert Traffic.answers(Traffic.summary()) == "200×2 429×1"
  end

  test "reset/0 starts a fresh account" do
    Traffic.request(200, 10, 100)

    Traffic.reset()

    assert Traffic.summary().requests == 0
    assert Traffic.summary().statuses == %{}
  end
end
