defmodule ConfluencePhxMirror.Mirror.Search.FiltersTest do
  @moduledoc """
  The "updated" filter, which is a menu a reader picks from: a named day, a
  number of days back, or a date typed by hand.

  The filter is a private function, so these go through the query the reader's
  screen actually sends.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Search.Filters

  describe "the updated filter" do
    test "today means since this morning" do
      assert cql(%{"updated" => "today"}) == ~s(lastmodified > "#{today()}")
    end

    test "yesterday means since the day before" do
      assert cql(%{"updated" => "yesterday"}) == ~s(lastmodified > "#{days_ago(1)}")
    end

    test "a number of days is counted back from today" do
      assert cql(%{"updated" => "7d"}) == ~s(lastmodified > "#{days_ago(7)}")
    end

    test "a date is taken as it is" do
      assert cql(%{"updated" => "2026-01-31"}) == ~s(lastmodified > "2026-01-31")
    end

    test "a menu option the mirror does not know adds no date filter" do
      assert cql(%{"q" => "rate limit", "updated" => "soon"}) == ~s(text ~ "rate limit")
    end
  end

  defp cql(params) do
    assert {:ok, cql, _terms} = Filters.to_cql(params)
    cql
  end

  defp today, do: Date.utc_today() |> Date.to_iso8601()
  defp days_ago(days), do: Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()
end
