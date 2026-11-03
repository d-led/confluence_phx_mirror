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
end
