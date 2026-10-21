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
