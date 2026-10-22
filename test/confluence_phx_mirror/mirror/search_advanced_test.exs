defmodule ConfluencePhxMirror.Mirror.SearchAdvancedTest do
  @moduledoc """
  The four text boxes of advanced search, several spaces at once, a date range,
  a contributor and an explicit sort — the questions a reader with a wide mirror
  actually asks, expressed as the engine's query language.
  """
  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror.Search

  setup do
    eng = space_fixture(%{key: "ENG", name: "Engineering"})
    prod = space_fixture(%{key: "PROD", name: "Product"})

    page_fixture(eng, %{
      title: "Rate limiting",
      body_storage: "<p>A token bucket guards the gateway against bursts.</p>",
      search_text: "A token bucket guards the gateway against bursts.",
      labels: ["architecture"],
      author_name: "Jane Doe"
    })

    page_fixture(eng, %{
      title: "Gateway runbook",
      body_storage: "<p>Rotate the certificate, then watch the rate limiter.</p>",
      search_text: "Rotate the certificate, then watch the rate limiter.",
      labels: ["runbook"],
      author_name: "Ops Robot"
    })

    page_fixture(prod, %{
      title: "Release 2.0",
      body_storage: "<p>Draft notes about the rate limit we are about to lift.</p>",
      search_text: "Draft notes about the rate limit we are about to lift.",
      labels: ["release"],
      author_name: "Jane Doe"
    })

    :ok
  end

  defp titles(results), do: results |> Enum.map(& &1.page.title) |> Enum.sort()

  test "an exact phrase finds only the page that has those words in that order" do
    assert {:ok, results, _terms} = Search.structured(%{"phrase" => "token bucket"})

    assert titles(results) == ["Rate limiting"]
  end

  test "any of these words widens the search" do
    assert {:ok, results, _} = Search.structured(%{"any" => "certificate draft"})

    assert titles(results) == ["Gateway runbook", "Release 2.0"]
  end

  test "none of these words excludes pages" do
    assert {:ok, results, _} = Search.structured(%{"q" => "rate", "none" => "draft"})

    assert titles(results) == ["Gateway runbook", "Rate limiting"]
  end

  test "several spaces at once search all of them" do
    assert {:ok, results, _} = Search.structured(%{"spaces" => "ENG,PROD"})

    assert titles(results) == ["Gateway runbook", "Rate limiting", "Release 2.0"]
  end

  test "a contributor filter keeps what that person wrote" do
    assert {:ok, results, _} = Search.structured(%{"creator" => "Jane Doe"})

    assert titles(results) == ["Rate limiting", "Release 2.0"]
  end

  test "a date range keeps only what changed inside it" do
    yesterday = Date.utc_today() |> Date.add(-1) |> DateTime.new!(~T[12:00:00], "Etc/UTC")

    page_fixture(space_fixture(%{key: "OPS"}), %{
      title: "Yesterday's note",
      body_storage: "<p>rate</p>",
      search_text: "rate",
      external_updated_at: yesterday
    })

    from = yesterday |> DateTime.to_date() |> Date.to_iso8601()
    to = Date.utc_today() |> Date.to_iso8601()

    assert {:ok, results, _} = Search.structured(%{"from" => from, "to" => to})

    assert titles(results) == ["Yesterday's note"]
  end

  test "results can be ordered by recency instead of relevance" do
    newest = Date.utc_today() |> DateTime.new!(~T[18:00:00], "Etc/UTC")

    page_fixture(space_fixture(%{key: "OPS"}), %{
      title: "Fresh rate note",
      body_storage: "<p>rate</p>",
      search_text: "rate",
      external_updated_at: newest
    })

    assert {:ok, relevance_first, _} = Search.structured(%{"q" => "rate"})
    assert {:ok, newest_first, _} = Search.structured(%{"q" => "rate"}, sort: :newest)
    assert {:ok, oldest_first, _} = Search.structured(%{"q" => "rate"}, sort: :oldest)

    assert relevance_first != []
    assert hd(newest_first).page.title == "Fresh rate note"
    assert List.last(oldest_first).page.title == "Fresh rate note"
  end

  test "sorting and paging agree on which window a page holds" do
    assert {:ok, first_page, _} = Search.structured(%{"q" => "rate"}, sort: :oldest, limit: 1)

    assert {:ok, second_page, _} =
             Search.structured(%{"q" => "rate"}, sort: :oldest, limit: 1, start: 1)

    assert hd(first_page).page.id != hd(second_page).page.id
    assert hd(first_page).page.external_updated_at <= hd(second_page).page.external_updated_at
  end
end
