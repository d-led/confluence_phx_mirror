defmodule ConfluencePhxMirror.Mirror.Search.CQLTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Search.CQL
  alias ConfluencePhxMirror.Mirror.Search.CQL.Query

  describe "fields and operators" do
    test "parses a single equality" do
      assert {:ok, %Query{filter: {:cmp, :space, :eq, "ENG"}}} = CQL.parse("space = ENG")
    end

    test "parses text search with ~" do
      assert {:ok, %Query{filter: {:cmp, :text, :contains, "rate limit"}}} =
               CQL.parse(~s(text ~ "rate limit"))
    end

    test "parses numeric fields as numbers" do
      assert {:ok, %Query{filter: {:cmp, :ancestor, :eq, 1000}}} =
               CQL.parse("ancestor = 1000")
    end

    test "parses dates into UTC datetimes" do
      assert {:ok, %Query{filter: {:cmp, :lastmodified, :gt, datetime}}} =
               CQL.parse(~s(lastmodified > "2026-10-01"))

      assert datetime == ~U[2026-10-01 00:00:00Z]
    end

    test "accepts single quotes too" do
      assert {:ok, %Query{filter: {:cmp, :label, :eq, "architecture"}}} =
               CQL.parse("label = 'architecture'")
    end
  end

  describe "boolean logic" do
    test "AND binds tighter than OR" do
      assert {:ok, %Query{filter: filter}} =
               CQL.parse("space = ENG AND label = architecture OR type = blogpost")

      assert filter ==
               {:or, {:and, {:cmp, :space, :eq, "ENG"}, {:cmp, :label, :eq, "architecture"}},
                {:cmp, :type, :eq, "blogpost"}}
    end

    test "parentheses override precedence" do
      assert {:ok, %Query{filter: filter}} =
               CQL.parse("space = ENG AND (label = architecture OR label = design)")

      assert filter ==
               {:and, {:cmp, :space, :eq, "ENG"},
                {:or, {:cmp, :label, :eq, "architecture"}, {:cmp, :label, :eq, "design"}}}
    end

    test "supports NOT on a group" do
      assert {:ok, %Query{filter: filter}} = CQL.parse("NOT (space = PROD OR type = blogpost)")

      assert filter == {:not, {:or, {:cmp, :space, :eq, "PROD"}, {:cmp, :type, :eq, "blogpost"}}}
    end
  end

  describe "order and limit" do
    test "parses ORDER BY with direction" do
      assert {:ok, %Query{order_by: {:title, :asc}}} =
               CQL.parse("space = ENG ORDER BY title ASC")
    end

    test "defaults ORDER BY to descending" do
      assert {:ok, %Query{order_by: {:lastmodified, :desc}}} =
               CQL.parse("space = ENG ORDER BY lastmodified")
    end

    test "parses LIMIT" do
      assert {:ok, %Query{limit: 5}} = CQL.parse("space = ENG LIMIT 5")
    end
  end

  describe "errors" do
    test "rejects unknown fields" do
      assert {:error, message} = CQL.parse("colour = blue")
      assert message =~ "unknown field"
    end

    test "rejects unterminated strings" do
      assert {:error, "unterminated string"} = CQL.parse(~s(text ~ "oops))
    end

    test "rejects a missing value" do
      assert {:error, message} = CQL.parse("space =")
      assert message =~ "expected a value"
    end

    test "rejects invalid dates" do
      assert {:error, message} = CQL.parse(~s(created > "yesterday"))
      assert message =~ "invalid date"
    end

    test "rejects unknown order fields" do
      assert {:error, message} = CQL.parse("space = ENG ORDER BY body")
      assert message =~ "cannot order by"
    end

    test "rejects trailing garbage" do
      assert {:error, message} = CQL.parse("space = ENG whatever")
      assert message =~ "unexpected trailing tokens"
    end
  end
end
