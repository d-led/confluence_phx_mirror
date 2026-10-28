defmodule ConfluencePhxMirror.Mirror.Search.CqlOperatorsTest do
  @moduledoc """
  The operators and functions Confluence documents that the mirror now reads.

  Each test states the same question twice where it can — once in the short form
  (`in`, `!~`, a date function) and once in the long one it stands for — because
  that equivalence is the promise: a reader who knows CQL should not have to
  learn which spelling this mirror accepts.
  """
  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror.Search

  setup do
    eng = space_fixture(%{key: "ENG", name: "Engineering"})
    prod = space_fixture(%{key: "PROD", name: "Product"})
    same_day = ~U[2026-10-20 12:00:00Z]

    page_fixture(eng, %{
      title: "Rate limiting",
      search_text: "a token bucket guards the gateway",
      labels: ["architecture"],
      external_updated_at: same_day
    })

    page_fixture(eng, %{
      title: "Gateway runbook",
      search_text: "rotate the certificate",
      labels: ["runbook", "ops"],
      external_updated_at: same_day
    })

    page_fixture(prod, %{
      title: "Release 2.0",
      search_text: "draft notes about the rate limit",
      labels: ["release"],
      type: "blogpost",
      external_updated_at: same_day
    })

    :ok
  end

  test "IN asks for several values at once, which is what OR spells out" do
    assert sorted_titles("space in (ENG, PROD)") == [
             "Gateway runbook",
             "Rate limiting",
             "Release 2.0"
           ]

    assert titles("space in (ENG, PROD)") == titles("space = ENG or space = PROD")
  end

  test "label IN finds content carrying any of the labels" do
    assert titles("label in (architecture, release)") == ["Rate limiting", "Release 2.0"]
  end

  test "NOT IN keeps what carries none of them" do
    assert titles("label not in (architecture, release)") == ["Gateway runbook"]
  end

  test "type IN lists several kinds of content" do
    assert sorted_titles("type in (page, blogpost)") == [
             "Gateway runbook",
             "Rate limiting",
             "Release 2.0"
           ]
  end

  test "!~ drops the pages whose title matches" do
    assert sorted_titles("title !~ release") == ["Gateway runbook", "Rate limiting"]
  end

  test "IN works on the stored columns too, ids and titles alike" do
    space = space_fixture(%{key: "OPS"})
    page_fixture(space, %{confluence_id: 7001, title: "One"})
    page_fixture(space, %{confluence_id: 7002, title: "Two"})
    page_fixture(space, %{confluence_id: 7003, title: "Three"})

    assert sorted_titles("id in (7001, 7002)") == ["One", "Two"]

    assert sorted_titles(~s{title in ("rate limiting", "release 2.0")}) == [
             "Rate limiting",
             "Release 2.0"
           ]
  end

  test "a date function is the instant it resolves to" do
    fresh = DateTime.utc_now() |> DateTime.truncate(:second)
    page_fixture(space_fixture(%{key: "OPS"}), %{title: "Fresh note", external_updated_at: fresh})

    assert titles(~s{lastmodified > now("-1h")}) == ["Fresh note"]

    assert titles(~s{lastmodified > now("-1h")}) ==
             titles(~s{lastmodified >= "#{DateTime.to_iso8601(fresh)}"})
  end

  test "startOfDay() reaches back to midnight, so today's page is still inside" do
    fresh = DateTime.utc_now() |> DateTime.truncate(:second)
    page_fixture(space_fixture(%{key: "OPS"}), %{title: "Fresh note", external_updated_at: fresh})

    assert "Fresh note" in titles("lastmodified >= startOfDay()")
  end

  test "ORDER BY two fields breaks the tie by the second" do
    assert titles("space = ENG order by lastmodified desc, title asc") == [
             "Gateway runbook",
             "Rate limiting"
           ]

    assert titles("space = ENG order by lastmodified desc, title desc") == [
             "Rate limiting",
             "Gateway runbook"
           ]
  end

  defp titles(cql, opts \\ []) do
    {:ok, results} = Search.search(cql, opts)
    Enum.map(results, & &1.page.title)
  end

  # Pages that share a timestamp are ordered by nothing in particular, so a test
  # about *which* pages match compares them as a set.
  defp sorted_titles(cql), do: cql |> titles() |> Enum.sort()
end
