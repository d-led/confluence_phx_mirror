defmodule ConfluencePhxMirror.Mirror.Search.CQL.FunctionsTest do
  @moduledoc """
  What "today", "this week" and "a month ago" mean to a query.

  A date function has to become one instant when the query is parsed: the mirror
  answers a query once for every reader, so nothing later can ask what "now" was
  when it was written. The cases worth pinning are the ones where the calendar is
  not plain arithmetic — a month step off the 31st, the last second of a range a
  comparison reads inclusively — and the refusals the parser relies on.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Search.CQL.Functions

  @now ~U[2026-10-28 15:04:05Z]

  test "a day's edges are its midnight and its last second" do
    assert Functions.resolve("startOfDay", [], @now) == {:ok, ~U[2026-10-28 00:00:00Z]}
    assert Functions.resolve("endOfDay", [], @now) == {:ok, ~U[2026-10-28 23:59:59Z]}
  end

  test "a week runs Monday to Sunday" do
    assert Functions.resolve("startOfWeek", [], @now) == {:ok, ~U[2026-10-26 00:00:00Z]}
    assert Functions.resolve("endOfWeek", [], @now) == {:ok, ~U[2026-11-01 23:59:59Z]}
  end

  test "a month ends where the calendar says, February included" do
    assert Functions.resolve("endOfMonth", [], ~U[2026-02-10 15:04:05Z]) ==
             {:ok, ~U[2026-02-28 23:59:59Z]}

    assert Functions.resolve("endOfMonth", [], ~U[2028-02-10 15:04:05Z]) ==
             {:ok, ~U[2028-02-29 23:59:59Z]}
  end

  test "a year's edges are its first and its last second" do
    assert Functions.resolve("startOfYear", [], @now) == {:ok, ~U[2026-01-01 00:00:00Z]}
    assert Functions.resolve("endOfYear", [], @now) == {:ok, ~U[2026-12-31 23:59:59Z]}
  end

  # Calendar arithmetic, not seconds: a month after the 31st is the last day of
  # the month it lands in, never a day that does not exist.
  test "a month step keeps the day, or lands on the month's last" do
    assert Functions.resolve("now", ["+1M"], ~U[2026-01-31 10:00:00Z]) ==
             {:ok, ~U[2026-02-28 10:00:00Z]}

    assert Functions.resolve("now", ["+1M"], ~U[2026-01-15 10:00:00Z]) ==
             {:ok, ~U[2026-02-15 10:00:00Z]}
  end

  test "every unit the grammar allows moves the instant it names" do
    assert Functions.resolve("now", ["-2y"], @now) == {:ok, ~U[2024-10-28 15:04:05Z]}
    assert Functions.resolve("now", ["+1w"], @now) == {:ok, ~U[2026-11-04 15:04:05Z]}
    assert Functions.resolve("now", ["-3d"], @now) == {:ok, ~U[2026-10-25 15:04:05Z]}
    assert Functions.resolve("now", ["2h"], @now) == {:ok, ~U[2026-10-28 17:04:05Z]}
    assert Functions.resolve("now", ["-30m"], @now) == {:ok, ~U[2026-10-28 14:34:05Z]}
  end

  test "an increment it cannot read is refused, and so is a second one" do
    assert {:error, message} = Functions.resolve("now", ["soon"], @now)
    assert message =~ ~s(expected an increment like "-7d")

    assert {:error, message} = Functions.resolve("now", ["-7d", "+1w"], @now)
    assert message =~ "at most one increment"
  end

  test "the functions that depend on who is asking are named, so the parser can refuse them" do
    assert Functions.user_specific?("currentUser")
    assert Functions.known?("endOfMonth")
    refute Functions.known?("favouriteSpaces")
  end
end
