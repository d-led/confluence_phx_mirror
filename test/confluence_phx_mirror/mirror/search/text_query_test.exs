defmodule ConfluencePhxMirror.Mirror.Search.TextQueryTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Search.TextQuery

  describe "parsing" do
    test "plain words are ANDed and prefix-matched" do
      assert {:ok, tsquery, terms} = TextQuery.parse("rate limit")

      assert tsquery == "('rate':* & 'limit':*)"
      assert Enum.sort(terms) == ["limit", "rate"]
    end

    test "quoted phrases stay phrases" do
      assert {:ok, "'rate' <-> 'limit'", ["rate", "limit"]} = TextQuery.parse(~s("rate limit"))
    end

    test "supports OR, AND, NOT and parentheses" do
      assert {:ok, tsquery, _terms} = TextQuery.parse("rate OR (roadmap AND NOT legacy)")
      assert tsquery =~ "|"
      assert tsquery =~ "&"
      assert tsquery =~ "!"
    end

    test "a leading minus excludes a term" do
      assert {:ok, "('rate':* & !('limit':*))", _terms} = TextQuery.parse("rate -limit")
    end

    test "dotted and hyphenated words stay single lexemes, as Postgres indexes them" do
      assert {:ok, "'roadmap.csv':*", ["roadmap.csv"]} = TextQuery.parse("roadmap.csv")
      assert {:ok, "'state-of-the-art':*", _terms} = TextQuery.parse("state-of-the-art")
    end

    test "surrounding punctuation is dropped" do
      assert {:ok, "'rate':*", ["rate"]} = TextQuery.parse("rate,")
    end

    test "empty input is empty" do
      assert TextQuery.parse("   ") == :empty
    end

    test "malformed input asks for a fallback" do
      assert TextQuery.parse(~s("rate limit)) == :error
      assert TextQuery.parse("(rate OR limit") == :error
    end
  end
end
