defmodule ConfluencePhxMirrorWeb.TimeTest do
  @moduledoc """
  How the mirror says *when* something happened: coarse on purpose, because a
  reader cares about "3 hours ago", not about a timestamp with seconds.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirrorWeb.Time

  describe "ago/1" do
    test "says never for content that was never synced" do
      assert Time.ago(nil) == "never"
    end

    test "keeps the last minute vague" do
      assert ago(seconds: 5) == "just now"
      assert ago(seconds: 40) == "just now"
    end

    test "rounds up to whole minutes and hours" do
      assert ago(seconds: 60) == "a minute ago"
      assert ago(seconds: 40 * 60) == "40 minutes ago"
      assert ago(seconds: 50 * 60) == "an hour ago"
      assert ago(seconds: 3600) == "an hour ago"
      assert ago(seconds: 3 * 3600 + 300) == "3 hours ago"
    end

    test "counts days, months and years in words" do
      assert ago(seconds: 30 * 3600) == "a day ago"
      assert ago(seconds: 5 * 86_400) == "5 days ago"
      assert ago(seconds: 90 * 86_400) == "3 months ago"
      assert ago(seconds: 400 * 86_400) == "a year ago"
      assert ago(seconds: 800 * 86_400) == "2 years ago"
    end

    test "speaks of the future when asked about a future timestamp" do
      assert ago(seconds: -3 * 3600) == "in 3 hours"
    end
  end

  describe "date/1 and datetime/1" do
    test "spell a date for a human" do
      assert Time.date(~U[2026-10-21 09:30:00Z]) == "21 Oct 2026"
      assert Time.date(nil) == "unknown"
    end

    test "say which clock a timestamp came from" do
      assert Time.datetime(~U[2026-10-21 09:30:00Z]) == "21 Oct 2026, 09:30 UTC"
      assert Time.datetime(nil) == "unknown"
    end

    test "always read an instant on the UTC clock" do
      # 11:30 in Berlin is 09:30 UTC, whichever way the value is stated.
      berlin = %DateTime{
        ~U[2026-10-21 11:30:00Z]
        | time_zone: "Europe/Berlin",
          zone_abbr: "CET",
          utc_offset: 7200
      }

      assert Time.iso(berlin) == "2026-10-21T09:30:00Z"
      assert Time.datetime(berlin) == "21 Oct 2026, 09:30 UTC"
      assert Time.date(berlin) == "21 Oct 2026"
    end

    test "put a timestamp near midnight on the UTC day it happened" do
      # Half past midnight in Berlin is still the evening before in UTC.
      berlin = %DateTime{
        ~U[2026-10-21 00:30:00Z]
        | time_zone: "Europe/Berlin",
          zone_abbr: "CEST",
          utc_offset: 7200
      }

      assert Time.date(berlin) == "20 Oct 2026"
      assert Time.datetime(berlin) == "20 Oct 2026, 22:30 UTC"
    end
  end

  describe "duration/2" do
    test "is missing when either end of a sync run is missing" do
      assert Time.duration(nil, ~U[2026-10-21 09:30:00Z]) == "—"
      assert Time.duration(~U[2026-10-21 09:30:00Z], nil) == "—"
    end

    test "picks the unit a reader can act on" do
      assert Time.duration(~U[2026-10-21 09:30:00Z], ~U[2026-10-21 09:30:00Z]) == "0 ms"
      assert Time.duration(~U[2026-10-21 09:30:00Z], ~U[2026-10-21 09:30:01Z]) == "1.0 s"
      assert Time.duration(~U[2026-10-21 09:30:00Z], ~U[2026-10-21 09:34:00Z]) == "4 min"
    end
  end

  # A timestamp `seconds` in the past; a negative value is in the future.
  defp ago(seconds: seconds) do
    Time.ago(DateTime.add(DateTime.utc_now(), -seconds, :second))
  end
end
