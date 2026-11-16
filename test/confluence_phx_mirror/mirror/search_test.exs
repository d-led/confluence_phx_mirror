defmodule ConfluencePhxMirror.Mirror.SearchTest do
  use ConfluencePhxMirror.DataCase, async: false

  # The deployment's search: the CQL its reader UI speaks, comment hits, and
  # ranking over a `tsvector`. The tool has an index of its own (`Search.Lite`,
  # FTS5) but no query-language parser, so this runs where the engine does —
  # see `test/test_helper.exs`.
  @moduletag :postgres_only

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

  # What a reader gets for what they typed into the search box.
  defp typed(q) do
    {:ok, results, _terms} = Search.structured(%{"q" => q})
    Enum.map(results, & &1.page.title)
  end

  test "filters by space and label" do
    assert titles("space = ENG AND label = architecture") == ["Architecture Overview"]
  end

  test "filters by ancestor" do
    assert "Getting Started" in titles("ancestor = 1000")
    assert "Release 2.0" not in titles("ancestor = 1000")
  end

  # `ancestor in` asks about a set of branches at once rather than one; it is a
  # different SQL shape from `ancestor =` (an overlap with the stored array
  # rather than one membership test), so it is executed rather than assumed to
  # follow.
  test "ancestor IN takes several branches at once" do
    assert Enum.sort(titles("ancestor in (1000)")) == Enum.sort(titles("ancestor = 1000"))

    # A union is more than one page of results, so the limit is raised: the
    # screen's own limit would truncate both lists in different places and the
    # comparison would be about ordering rather than about which pages match.
    assert Enum.sort(titles("ancestor in (1000, 2000)", limit: 200)) ==
             Enum.sort(
               titles("ancestor = 1000", limit: 200) ++ titles("ancestor = 2000", limit: 200)
             )
  end

  # `parent in` is the direct parent only — the difference between "under this
  # page, however deep" and "one step below it".
  test "parent IN names the direct children" do
    assert Enum.sort(titles("parent in (1000)")) == Enum.sort(titles("parent = 1000"))
    assert "Getting Started" in titles("parent in (1000)")
    refute "Getting Started" in titles("parent in (1001)")
  end

  test "finds blog posts by type" do
    assert titles("type = blogpost") == ["Release 2.0"]
  end

  test "full-text search matches body text and returns a snippet" do
    {:ok, results} = Search.search(~s(text ~ "rate limit"))

    assert results != []
    assert Enum.any?(results, &(&1.snippet =~ "rate limit"))
  end

  # A Confluence id is what a colleague pastes in from a URL or a ticket, and it
  # is in no text index — nobody writes a page called "426221". The reader's
  # search box reaches `structured/2`, which is the path this pins.
  test "a page id finds its page" do
    # First, too: a page that merely repeats the number in its text is a worse
    # answer than the page the number names.
    assert ["Architecture Overview" | _] = typed("1002")
  end

  test "a page id that nothing has finds nothing" do
    assert typed("426221") == []
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

    # The page can be a hit on its title alone, and then there is no word in the
    # body to open at: the reader still gets the first line rather than nothing.
    test "open at the beginning when no term is in the words" do
      page = %ConfluencePhxMirror.Mirror.Page{body_text: "  a page about queues  "}

      assert Search.snippet(page, ["networking"]) == "a page about queues"
    end

    test "a body with no words has no snippet" do
      assert Search.snippet(%ConfluencePhxMirror.Mirror.Page{body_text: nil}, ["x"]) == ""
      assert Search.snippet(%ConfluencePhxMirror.Mirror.Page{body_text: ""}, ["x"]) == ""
      assert Search.snippet(%ConfluencePhxMirror.Mirror.Comment{body_text: nil}, ["x"]) == ""
      assert Search.snippet(%ConfluencePhxMirror.Mirror.Comment{body_text: ""}, ["x"]) == ""
    end

    # A search with no filter has no terms to open a snippet on, which is the
    # question a results list asks once for the whole page rather than per hit.
    test "a search with no filter asks for no terms" do
      assert Search.terms(nil) == []
    end

    test "a comment's words are worth a snippet too" do
      comment = %ConfluencePhxMirror.Mirror.Comment{body_text: "the rate limit is 240"}

      assert Search.snippet(comment, ["rate limit"]) == "the rate limit is 240"
    end

    # A body can be one unbroken token — a pasted hash, a base64 blob — and then
    # there is no space to open on: the window is shown as it is, without an
    # ellipsis promising words it does not contain.
    test "an unbroken run of characters is shown as it is" do
      text = String.duplicate("x", 300) <> "needle"
      page = %ConfluencePhxMirror.Mirror.Page{body_text: text}

      assert Search.snippet(page, ["needle"]) == String.slice(text, 220, 240)
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
      {:ok, ranked, _terms} = Search.structured(%{"q" => "pipeline"})
      {:ok, scoped, terms} = Search.structured(%{"q" => "pipeline", "space" => "ENG"})

      assert Enum.all?(scoped, &(&1.space.key == "ENG"))

      # The filter narrows the ranking; it does not reorder it.
      in_space = Enum.filter(ranked, &(&1.space.key == "ENG"))
      assert scoped != []
      assert Enum.map(scoped, & &1.page.title) == Enum.map(in_space, & &1.page.title)

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
