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
  #
  # The shell itself costs two: the space switcher is a LiveView rendered into
  # every page, and it reads the window of spaces it offers (one), and telling
  # whether a personal space is mirrored is an existence check on the screens
  # that count readership (one). Neither grows with the content.
  test "the home page loads its content in a bounded number of queries", %{conn: conn} do
    queries = QueryCounter.count(fn -> get(conn, ~p"/") end)

    assert queries <= 16, "home page issued #{queries} queries"
  end

  # The space landing (`/spaces/:key`) is the space home page — the screen the
  # page's own URL renders — so it carries the page view's cost, one space
  # lookup included; the overview it falls back to, and which
  # `/spaces/:key/overview` renders, is cheaper than that. Both are today's
  # numbers, so they can only go down.
  #
  # The first request of a test builds the caches the totals live in, which is
  # why the budget is pinned on the answer after one warm-up.
  test "a space's landing page does not query per page", %{conn: conn} do
    get(conn, ~p"/spaces/ENG/overview")

    overview = QueryCounter.count(fn -> get(conn, ~p"/spaces/ENG/overview") end)
    landing = QueryCounter.count(fn -> get(conn, ~p"/spaces/ENG") end)

    assert overview <= 17, "space overview issued #{overview} queries"
    assert landing <= 24, "space landing issued #{landing} queries"
  end

  # A page renders the readers badge twice: the rail names who is here, and the
  # metadata row repeats the count where the rail is hidden. The second
  # `PagePresenceLive` mounts with the rail's, and it repeats the rail's three
  # statements — the reader's scope, the page, whether it may be read — so the
  # ceiling below moved by exactly those three, not by three per page on the
  # screen.
  test "deep page rendering stays bounded", %{conn: conn} do
    queries =
      QueryCounter.count(fn -> get(conn, "/spaces/ENG/pages/1002/Architecture+Overview") end)

    assert queries <= 25, "page view issued #{queries} queries"
  end

  # "rate" is a word the mirror knows few of, which is the case the fragment pass
  # was written for: when a one-word query comes up short, the same word is asked
  # again as a fragment ("scal" finds "Escalation"). That second pass is three
  # statements — its own query, the pages it returns and their spaces — and it
  # costs nothing for a query that fills the page, which is why the ceiling moved
  # by exactly those three and not by a number that grows with the content.
  test "search and the people directory stay bounded", %{conn: conn} do
    search = QueryCounter.count(fn -> get(conn, ~p"/search?q=rate") end)
    people = QueryCounter.count(fn -> get(conn, ~p"/people") end)

    assert search <= 24, "search issued #{search} queries"
    assert people <= 12, "people directory issued #{people} queries"
  end
end
