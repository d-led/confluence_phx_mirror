defmodule ConfluencePhxMirrorWeb.QueryBudgetTest do
  @moduledoc """
  How many queries a screen costs.

  An N+1 shows up here as a number that grows with the content, not as a
  stopwatch. Each case pins the budget one page may spend, so a `preload` that
  quietly disappeared fails the suite instead of slowing a reader down.

  These budgets run over the demo snapshot; `ScaleTest` holds the same shapes to
  a budget with a thousand spaces behind them.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.QueryCounter

  setup do
    demo_snapshot!()
    :ok
  end

  # The home page currently spends two queries per space (a space read and a
  # page read), which is the finding this guard was written for: the ceiling is
  # today's number, so it can only go down. The totals it prints are cached
  # against a version probe, which is two of these queries on a cold cache.
  test "the home page loads its content in a bounded number of queries", %{conn: conn} do
    queries = QueryCounter.count(fn -> get(conn, ~p"/") end)

    assert queries <= 14, "home page issued #{queries} queries"
  end

  test "a space overview does not query per page", %{conn: conn} do
    queries = QueryCounter.count(fn -> get(conn, ~p"/spaces/ENG") end)

    assert queries <= 8, "space overview issued #{queries} queries"
  end

  test "deep page rendering stays bounded", %{conn: conn} do
    queries =
      QueryCounter.count(fn -> get(conn, ~p"/spaces/ENG/pages/1002/architecture-overview") end)

    assert queries <= 21, "page view issued #{queries} queries"
  end

  test "search and the people directory stay bounded", %{conn: conn} do
    search = QueryCounter.count(fn -> get(conn, ~p"/search?q=rate") end)
    people = QueryCounter.count(fn -> get(conn, ~p"/people") end)

    assert search <= 25, "search issued #{search} queries"
    assert people <= 12, "people directory issued #{people} queries"
  end
end
