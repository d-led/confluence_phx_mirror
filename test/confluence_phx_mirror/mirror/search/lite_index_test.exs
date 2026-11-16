defmodule ConfluencePhxMirror.Mirror.Search.LiteIndexTest do
  @moduledoc """
  The desktop tool's search against its own store: FTS5 over `pages.title` and
  `pages.body_text`, with the reader's filters as `AND` clauses and `bm25` for
  rank.

  `lite_test.exs` pins what a reader's words become and what a result holds; this
  file asks the index, because until it existed nothing did. The Postgres job
  cannot — the table is not there — so it runs in the SQLite leg alone
  (`:sqlite_only`), and a broken statement would otherwise have shipped as "the
  search box finds nothing".
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.Search.Lite

  @moduletag :sqlite_only

  setup do
    demo_snapshot!()
    :ok
  end

  test "a word from a page's title finds that page" do
    assert {:ok, results} = Lite.text("architec")

    assert Enum.any?(results, &(&1.page.confluence_id == 1002))
  end

  test "a word no page carries finds nothing" do
    assert {:ok, []} = Lite.text("zzzznothing")
  end

  test "a space narrows the answer to that space" do
    assert {:ok, results, _terms} = Lite.structured(%{"space" => "ENG"})

    assert results != []
    assert Enum.all?(results, &(&1.space.key == "ENG"))
  end

  test "a space nobody mirrored finds nothing" do
    assert {:ok, [], _terms} = Lite.structured(%{"space" => "NOSUCHSPACE"})
  end

  # The gallery page matches "architecture" and carries "overview", so excluding
  # "overview" must take it away: an exclusion is its own `NOT IN (… MATCH …)`,
  # because FTS5 has no unary NOT.
  test "a word the reader excluded is a page they do not see" do
    assert {:ok, results, _terms} =
             Lite.structured(%{"q" => "architecture", "none" => "overview"})

    refute Enum.any?(results, &(&1.page.confluence_id == 1002))
  end

  test "a trashed page is not a result" do
    assert {:ok, before} = Lite.text("architecture")
    assert Enum.any?(before, &(&1.page.confluence_id == 1002))

    {:ok, _} = Mirror.mark_deleted(1002)

    assert {:ok, after_trash} = Lite.text("architecture")
    refute Enum.any?(after_trash, &(&1.page.confluence_id == 1002))
  end

  # The demo snapshot mirrors one site and its dates are its own, so the two ends
  # are made from what is stored: one day before the oldest page and one day
  # after the newest. A date invented here would be a guess about the fixture.
  test "newest and oldest read the same list from its two ends" do
    {earliest, latest} =
      ConfluencePhxMirror.Repo.one(
        from p in ConfluencePhxMirror.Mirror.Page,
          select: {min(p.external_updated_at), max(p.external_updated_at)}
      )

    newer = page_by_confluence_id(1002)
    older = page_by_confluence_id(1003)

    set_updated(newer, DateTime.add(latest, 1, :day))
    set_updated(older, DateTime.add(earliest, -1, :day))

    assert {:ok, [first | _], _terms} = Lite.structured(%{"space" => "ENG"}, sort: :newest)
    assert first.page.id == newer.id

    assert {:ok, [last | _], _terms} = Lite.structured(%{"space" => "ENG"}, sort: :oldest)
    assert last.page.id == older.id
  end

  test "the CQL of the Confluence-compatible API is answered, not guessed at" do
    assert {:error, message} = Lite.search("space = ENG AND title ~ template", [])
    assert message =~ "filters, not as CQL"
  end

  defp page_by_confluence_id(id) do
    ConfluencePhxMirror.Repo.get_by!(ConfluencePhxMirror.Mirror.Page, confluence_id: id)
  end

  defp set_updated(page, at) do
    page
    |> Ecto.Changeset.change(external_updated_at: at)
    |> ConfluencePhxMirror.Repo.update!()
  end
end
