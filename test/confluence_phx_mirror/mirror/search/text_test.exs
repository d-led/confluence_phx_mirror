defmodule ConfluencePhxMirror.Mirror.Search.TextTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror.Search

  setup do
    demo_snapshot!()
    :ok
  end

  defp titles(query, opts \\ []) do
    {:ok, results} = Search.text(query, opts)
    Enum.map(results, & &1.page.title)
  end

  test "searches titles and body content" do
    assert "Architecture Overview" in titles("architecture")
    assert "Search and CQL" in titles("rate limit")
  end

  test "matches unquoted words by prefix" do
    assert "Architecture Overview" in titles("architect")
  end

  test "a fragment from inside a word finds the page, after the words that start with it" do
    space = space_fixture(%{key: "FRAG", name: "Fragments"})
    page_fixture(space, %{title: "Scalability notes", confluence_id: 97_001})
    page_fixture(space, %{title: "Escalation policy", confluence_id: 97_002})

    found = titles("scal")

    assert "Scalability notes" in found
    assert "Escalation policy" in found

    # A word that starts with what was typed is the better match, whatever the
    # other band scores: that is the promise of "prioritizing the first letter".
    assert Enum.find_index(found, &(&1 == "Scalability notes")) <
             Enum.find_index(found, &(&1 == "Escalation policy"))
  end

  test "a two-letter query stays a prefix search, because a trigram cannot index it" do
    space = space_fixture(%{key: "FRAG", name: "Fragments"})
    page_fixture(space, %{title: "Escalation policy", confluence_id: 97_003})

    # Below three characters the SQL that looks inside words is a scan of every
    # page's text — 390 ms on the pages this benchmark machine holds. The box is
    # used as a prefix as soon as it is worth typing into.
    refute "Escalation policy" in titles("sc")
  end

  test "searches labels, authors, spaces and attachment filenames" do
    assert "Architecture Overview" in titles("design")
    assert "Architecture Overview" in titles("jane doe")
    assert "Roadmap" in titles("roadmap.csv")
    assert titles("ENG") != []
  end

  test "supports quoted phrases" do
    assert "Search and CQL" in titles(~s("rate limit"))
    refute "Architecture Overview" in titles(~s("rate limit"))
  end

  test "supports OR and NOT" do
    assert "Roadmap" in titles("roadmap OR release")
    assert "Search and CQL" in titles("rate limit NOT roadmap")
  end

  test "malformed boolean expressions fall back instead of failing" do
    assert {:ok, results} = Search.text("rate (limit")
    assert is_list(results)
  end

  test "ranking prefers title matches" do
    {:ok, results} = Search.text("architecture")
    assert hd(results).page.title == "Architecture Overview"
    assert hd(results).rank > 0
  end
end
