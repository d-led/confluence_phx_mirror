defmodule ConfluencePhxMirror.Mirror.Search.CQLTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Search.CQL
  alias ConfluencePhxMirror.Mirror.Search.CQL.Query

  describe "fields and operators" do
    test "parses a single equality" do
      assert {:ok, %Query{filter: {:cmp, :space, :eq, "ENG"}}} = CQL.parse("space = ENG")
    end

    test "reads keywords and fields regardless of case" do
      assert {:ok, %Query{filter: {:and, {:cmp, :type, :eq, "page"}, {:cmp, :space, :eq, "DEV"}}}} =
               CQL.parse("type=page and Space=DEV")
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

  describe "set membership" do
    test "IN names a set of values" do
      assert {:ok, %Query{filter: {:in, :space, ["DEV", "QA"]}}} = CQL.parse("space in (DEV, QA)")
    end

    test "NOT IN excludes them" do
      assert {:ok, %Query{filter: {:not_in, :label, ["draft", "review"]}}} =
               CQL.parse("label not in (draft, review)")
    end

    test "validates each value the way a single one is validated" do
      assert {:ok, %Query{filter: {:in, :ancestor, [123, 456]}}} =
               CQL.parse("ancestor in (123, 456)")

      assert {:error, message} = CQL.parse("ancestor in (123, abc)")
      assert message =~ "ancestor expects a number"
    end

    test "rejects a list without parentheses" do
      assert {:error, message} = CQL.parse("space in DEV")
      assert message =~ "IN expects a list"
    end

    test "rejects a user-specific function inside a list" do
      assert {:error, message} = CQL.parse("space in favouriteSpaces()")
      assert message =~ "depends on who is asking"
    end
  end

  describe "does not contain" do
    test "parses !~ as the negation of a text match" do
      assert {:ok, %Query{filter: {:cmp, :title, :not_contains, "draft"}}} =
               CQL.parse("title !~ draft")
    end
  end

  describe "date functions" do
    test "now() without an increment is the moment of parsing" do
      before = DateTime.utc_now()

      assert {:ok, %Query{filter: {:cmp, :lastmodified, :gt, resolved}}} =
               CQL.parse("lastmodified > now()")

      assert DateTime.compare(resolved, before) in [:gt, :eq]
    end

    test "now() with a negative increment travels back in weeks" do
      assert {:ok, %Query{filter: {:cmp, :created, :gt, resolved}}} =
               CQL.parse(~s{created > now("-4w")})

      assert_in_delta DateTime.diff(DateTime.utc_now(), resolved), 4 * 7 * 86_400, 5
    end

    test ~s{startOfDay("-7d") is the midnight of a week ago} do
      assert {:ok, %Query{filter: {:cmp, :created, :gt, resolved}}} =
               CQL.parse(~s{created > startOfDay("-7d")})

      assert resolved.hour == 0 and resolved.minute == 0 and resolved.second == 0
      assert Date.diff(Date.utc_today(), DateTime.to_date(resolved)) == 7
    end

    test "endOfMonth() is the last second of this month" do
      assert {:ok, %Query{filter: {:cmp, :lastmodified, :lt, resolved}}} =
               CQL.parse("lastmodified < endOfMonth()")

      assert DateTime.to_date(resolved) == Date.end_of_month(Date.utc_today())
      assert {resolved.hour, resolved.minute} == {23, 59}
    end

    test "refuses a date function on a field that is not a date" do
      assert {:error, message} = CQL.parse("space = startOfDay()")
      assert message =~ "answers a date"
    end

    test "refuses currentUser(), because the mirror answers once for every reader" do
      assert {:error, message} = CQL.parse("creator = currentUser()")
      assert message =~ "depends on who is asking"
    end

    test "refuses a function the mirror never heard of" do
      assert {:error, message} = CQL.parse("created > tomorrow()")
      assert message =~ "unknown function"
    end

    test "refuses an increment it cannot read" do
      assert {:error, message} = CQL.parse(~s{created > now("soon")})
      assert message =~ "expected an increment"
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
      assert {:ok, %Query{order_by: [{:title, :asc}]}} =
               CQL.parse("space = ENG ORDER BY title ASC")
    end

    test "defaults ORDER BY to descending" do
      assert {:ok, %Query{order_by: [{:lastmodified, :desc}]}} =
               CQL.parse("space = ENG ORDER BY lastmodified")
    end

    test "orders by several fields, the way Confluence writes it" do
      assert {:ok, %Query{order_by: [{:created, :desc}, {:title, :asc}]}} =
               CQL.parse("space = ENG order by created desc, title asc")
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

    test "a field Confluence has but the mirror cannot answer says why" do
      assert {:error, message} = CQL.parse("watcher = currentUser()")
      assert message =~ "answers once for every reader"

      assert {:error, dotted} = CQL.parse("space.title ~ Architecture")
      assert dotted =~ "narrow by space key"
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
