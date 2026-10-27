defmodule ConfluencePhxMirror.Mirror.SearchTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror.Search
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.TestConfig

  setup do
    demo_snapshot!()
    :ok
  end

  defp titles(cql, opts \\ []) do
    {:ok, results} = Search.search(cql, opts)
    Enum.map(results, & &1.page.title)
  end

  test "filters by space and label" do
    assert titles("space = ENG AND label = architecture") == ["Architecture Overview"]
  end

  test "filters by ancestor" do
    assert "Getting Started" in titles("ancestor = 1000")
    assert "Release 2.0" not in titles("ancestor = 1000")
  end

  test "finds blog posts by type" do
    assert titles("type = blogpost") == ["Release 2.0"]
  end

  test "full-text search matches body text and returns a snippet" do
    {:ok, results} = Search.search(~s(text ~ "rate limit"))

    assert results != []
    assert Enum.any?(results, &(&1.snippet =~ "rate limit"))
  end

  describe "snippets" do
    test "open on a word boundary when the match sits deep in the text" do
      page = %ConfluencePhxMirror.Mirror.Page{
        body_text: String.duplicate("filler ", 40) <> "networking lives here"
      }

      snippet = Search.snippet(page, ["networking"])

      assert snippet =~ "networking lives here"
      assert String.starts_with?(snippet, "… filler")
    end

    test "start at the beginning when the match is already at the top" do
      page = %ConfluencePhxMirror.Mirror.Page{body_text: "networking lives here"}

      assert Search.snippet(page, ["networking"]) == "networking lives here"
    end
  end

  test "title search is case insensitive for equality" do
    assert titles(~s(title = "release 2.0")) == ["Release 2.0"]
  end

  test "orders and limits" do
    assert titles("space = ENG ORDER BY lastmodified DESC LIMIT 3") ==
             ["Meeting Notes", "Architecture Overview", "Engineering Handbook"]
  end

  test "supports pagination with start" do
    all = titles("space = ENG ORDER BY title ASC")
    page_two = titles("space = ENG ORDER BY title ASC", start: 2, limit: 2)
    assert page_two == Enum.slice(all, 2, 2)
  end

  test "excludes deleted pages" do
    page = ConfluencePhxMirror.Repo.get_by!(ConfluencePhxMirror.Mirror.Page, confluence_id: 1002)
    ConfluencePhxMirror.Mirror.mark_deleted(1002)

    refute "Architecture Overview" in titles("space = ENG")
    assert page.id
  end

  test "returns a meaningful error for invalid CQL" do
    assert {:error, message} = Search.search("colour = blue")
    assert message =~ "unknown field"
  end

  describe "structured search" do
    test "returns nothing before any criteria is given" do
      assert Search.structured(%{}) == {:ok, [], []}
    end

    test "applies field filters without text" do
      {:ok, results, []} = Search.structured(%{"space" => "ENG", "label" => "architecture"})
      assert Enum.map(results, & &1.page.title) == ["Architecture Overview"]
    end

    test "intersects text with field filters and keeps the text ranking" do
      {:ok, results, terms} = Search.structured(%{"q" => "pipeline", "space" => "ENG"})

      assert hd(results).page.title == "Architecture Overview"
      assert Enum.all?(results, &(&1.space.key == "ENG"))
      assert terms == ["pipeline"]
    end

    test "does not leak pages from other spaces" do
      {:ok, results, _terms} = Search.structured(%{"q" => "release", "space" => "OPS"})
      refute Enum.any?(results, &(&1.page.title == "Release 2.0"))
    end

    test "the result cap comes from configuration" do
      TestConfig.put(:search, max_limit: 1)

      {:ok, results} = Search.search("space = ENG", limit: 50)

      assert length(results) == 1
    end

    test "an administrator's cap overrides the configuration" do
      Settings.update(%{"search.max_results" => 2}, {:system, "test"})
      on_exit(fn -> Settings.forget() end)

      {:ok, results} = Search.search("space = ENG", limit: 50)

      assert length(results) == 2
    end
  end

  describe "CQL comparisons" do
    test "compares space, type and title with inequality" do
      assert "Release 2.0" in titles("space != ENG")
      refute "Architecture Overview" in titles("space != ENG")

      assert "Architecture Overview" in titles("type != blogpost")
      refute "Release 2.0" in titles("type != blogpost")

      assert titles(~s(title = "Architecture Overview")) == ["Architecture Overview"]
      refute "Architecture Overview" in titles(~s(title != "Architecture Overview"))
    end

    test "filters by creator, parent and id" do
      assert "Architecture Overview" in titles(~s(creator = "Jane Doe"))
      assert "Architecture Overview" in titles("parent = 1001")
      assert titles("id = 1002") == ["Architecture Overview"]
      assert titles("id = 999999") == []
    end

    test "compares numbers and dates on both sides of a bound" do
      assert titles("version > 10000") == []
      assert "Architecture Overview" in titles("version >= 1")
      assert titles("version < 0") == []
      assert "Architecture Overview" in titles("version <= 10000")

      assert titles(~s(created < "2000-01-01")) == []
      assert "Architecture Overview" in titles(~s(created <= "2026-10-21"))
      assert titles(~s(lastmodified < "2000-01-01")) == []
      assert "Architecture Overview" in titles(~s(lastmodified >= "2026-10-01"))
    end

    test "orders by the requested field instead of by recency" do
      {:ok, by_title} = Search.search("space = ENG ORDER BY title ASC")
      sorted = Enum.map(by_title, & &1.page.title) |> Enum.sort()
      assert Enum.map(by_title, & &1.page.title) == sorted

      {:ok, by_version} = Search.search("space = ENG ORDER BY version DESC")

      assert List.first(by_version).page.version_number >=
               List.last(by_version).page.version_number
    end
  end
end
