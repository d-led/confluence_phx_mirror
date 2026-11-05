defmodule ConfluencePhxMirror.Mirror.Search.LiteTest do
  @moduledoc """
  What a reader types becomes an FTS5 `MATCH` expression. FTS5's own syntax is
  unforgiving — a stray `-`, `*` or bracket is a syntax error, not a miss — so
  these cases are as much about what is *not* passed through as about what is.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Search.Lite

  describe "the reader's words" do
    test "every word is a quoted prefix, so a half-typed word still finds it" do
      assert Lite.match_expression(%{"q" => "scal"}) == ~s("scal"*)
      assert Lite.match_expression(%{"q" => "big red"}) == ~s("big"* AND "red"*)
    end

    test "no words is no expression, not an empty one" do
      assert Lite.match_expression(%{}) == nil
      assert Lite.match_expression(%{"q" => "   "}) == nil
    end

    test "punctuation is a search box's punctuation, never query syntax" do
      assert Lite.match_expression(%{"q" => ~s(rock'n'roll)}) == ~s("rock"* AND "n"* AND "roll"*)

      assert Lite.match_expression(%{"q" => "a -b +c *d (e)"}) ==
               ~s("a"* AND "b"* AND "c"* AND "d"* AND "e"*)
    end

    test "a paste accident is not a word" do
      pasted = String.duplicate("x", 61)

      assert Lite.match_expression(%{"q" => "short #{pasted}"}) == ~s("short"*)
    end
  end

  describe "the fields beside the words" do
    test "a phrase is read as adjacent tokens" do
      assert Lite.match_expression(%{"phrase" => "big red"}) == ~s("big red")
    end

    test "'any of these' is one group of alternatives" do
      assert Lite.match_expression(%{"any" => "red blue"}) == ~s|("red"* OR "blue"*)|
    end

    test "words, a phrase and alternatives are all demanded together" do
      assert Lite.match_expression(%{"q" => "mug", "phrase" => "big red", "any" => "red blue"}) ==
               ~s|"mug"* AND "big red" AND ("red"* OR "blue"*)|
    end

    test "an exclusion is its own expression, because FTS5's NOT is binary" do
      assert Lite.exclusions(%{"none" => "old, stale"}) == [~s("old"*), ~s("stale"*)]
      assert Lite.exclusions(%{}) == []
    end
  end

  # The other half of what a reader types: the fields around the words. Every
  # value below is a `?` and never part of the statement, which is what these
  # assertions are about as much as the clauses themselves.
  describe "the field filters become the SQL" do
    test "a space key is bound, and matched in the case Confluence writes it in" do
      assert Lite.where_clause(%{"space" => " eng "}) == {"\n      AND s.key = ?", ["ENG"]}
    end

    test "several spaces are one IN list, and a blank list is no filter" do
      assert Lite.where_clause(%{"spaces" => "eng, ops"}) ==
               {"\n      AND s.key IN (?,?)", ["ENG", "OPS"]}

      assert Lite.where_clause(%{"spaces" => " , "}) == {"", []}
    end

    test "a label is an EXISTS, because a page's labels are rows of their own" do
      {clauses, values} = Lite.where_clause(%{"label" => " Team "})

      assert values == ["team"]
      assert clauses =~ "EXISTS (SELECT 1 FROM page_labels"

      assert Lite.where_clause(%{"label" => "  "}) == {"", []}
    end

    test "several labels are several EXISTS clauses" do
      {clauses, values} = Lite.where_clause(%{"labels" => "team, v2"})

      assert values == ["team", "v2"]
      assert length(String.split(clauses, "EXISTS")) == 3
    end

    test "a content type is lower-cased, and a list of them is an IN list" do
      assert Lite.where_clause(%{"type" => "Page"}) == {"\n      AND p.type = ?", ["page"]}

      assert Lite.where_clause(%{"types" => "page, Blogpost"}) ==
               {"\n      AND p.type IN (?,?)", ["page", "blogpost"]}
    end

    test "a creator is whichever column the mirror filled" do
      assert Lite.where_clause(%{"creator" => "ada"}) ==
               {"\n      AND (p.author_account_id = ? OR p.author_name = ?)", ["ada", "ada"]}
    end

    test "an ancestor is looked for in the mirrored ancestor list" do
      assert Lite.where_clause(%{"ancestor" => "42"}) ==
               {"\n      AND EXISTS (SELECT 1 FROM json_each(p.ancestors) WHERE value = ?)",
                ["42"]}
    end

    test "a date is compared as a date, however it was written" do
      assert Lite.where_clause(%{"from" => "2024-01-31"}) ==
               {"\n      AND date(p.external_updated_at) > ?", ["2024-01-31"]}

      assert Lite.where_clause(%{"to" => "2024-02-01"}) ==
               {"\n      AND date(p.external_updated_at) < ?", ["2024-02-01"]}
    end

    test "a relative date is the one the search box offers" do
      week_ago = Date.utc_today() |> Date.add(-7) |> Date.to_iso8601()

      assert Lite.where_clause(%{"updated" => "7d"}) ==
               {"\n      AND date(p.external_updated_at) > ?", [week_ago]}

      assert Lite.where_clause(%{"updated_after" => "7d"}) ==
               {"\n      AND date(p.external_updated_at) > ?", [week_ago]}

      assert Lite.where_clause(%{"updated" => "any"}) == {"", []}
    end

    test "a title filter is a substring, so LIKE's own wildcards are escaped" do
      assert Lite.where_clause(%{"title" => "50%_off"}) ==
               {"\n      AND lower(coalesce(p.title, '')) LIKE lower(?)", ["%50\\%\\_off%"]}
    end

    test "the words are not filters, and neither is a parameter nothing implements" do
      assert Lite.where_clause(%{
               "q" => "mug",
               "phrase" => "big red",
               "any" => "red",
               "none" => "old"
             }) == {"", []}

      assert Lite.where_clause(%{"colour" => "red"}) == {"", []}
      assert Lite.where_clause(%{"space" => ""}) == {"", []}
    end

    test "filters are demanded together, in one WHERE" do
      assert Lite.where_clause(%{"space" => "eng", "type" => "page"}) ==
               {"\n      AND s.key = ?\n      AND p.type = ?", ["ENG", "page"]}
    end
  end

  describe "what a result holds" do
    alias ConfluencePhxMirror.Mirror.Page
    alias ConfluencePhxMirror.Mirror.Space

    defp page(id, title, text) do
      %Page{id: id, title: title, body_text: text, space: %Space{id: 7, name: "ENG"}}
    end

    test "a result carries its page, that page's space, and a rank higher-is-better" do
      pages = %{2 => page(2, "Scaling", "how we scale things"), 1 => page(1, "Ops", "on call")}

      assert [first, second] = Lite.results([2, 1], %{2 => -1.5, 1 => -0.5}, pages, ["scale"])
      assert first.page.title == "Scaling"
      assert first.space.name == "ENG"
      assert first.rank == 1.5
      assert first.snippet =~ "scale"
      assert first.comment == nil
      assert second.rank == 0.5
    end

    test "a row whose page was purged in between is dropped, not fatal" do
      pages = %{1 => page(1, "Ops", "on call")}

      assert [result] = Lite.results([9, 1], %{9 => -9.0, 1 => -0.5}, pages, [])
      assert result.page.id == 1
    end
  end

  describe "a search with nothing to ask" do
    test "asks the index nothing, rather than everything" do
      assert Lite.structured(%{"q" => "  ", "space" => ""}) == {:ok, [], []}
      assert Lite.structured(%{}) == {:ok, [], []}
    end
  end
end
