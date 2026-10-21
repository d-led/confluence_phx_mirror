defmodule ConfluencePhxMirror.Mirror.SearchTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror.Search

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
end
