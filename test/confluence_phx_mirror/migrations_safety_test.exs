defmodule ConfluencePhxMirror.MigrationsSafetyTest do
  @moduledoc """
  A deploy migration runs while the previous release is still serving, so it may
  only add things — see "What makes a deploy migration safe" in
  `docs/operations.md`.

  These are file checks rather than database checks: the rule is cheapest to
  hold at the moment a migration is written, and a migration that has shipped
  cannot be un-written.
  """

  use ExUnit.Case, async: true

  @deploy_migrations "priv/repo/migrations"

  # Migrations written before the rule existed, each with the shape the change
  # would take today. A new entry here is a decision, not an accident.
  @legacy %{
    "20261021180300_create_search_indexes.exs" =>
      "GIN and trigram builds after an added column — CREATE INDEX CONCURRENTLY",
    "20261021212215_add_service_api_tokens.exs" =>
      "an index build and a dropped NOT NULL — CONCURRENTLY, then expand/backfill/contract",
    "20261022054245_attachments_confluence_id_as_text.exs" =>
      "a column type change — expand, backfill, contract",
    "20261023120000_index_pages_updated_at.exs" =>
      "a plain index build — CREATE INDEX CONCURRENTLY",
    "20261023145432_index_api_token_prefix.exs" =>
      "a plain index build — CREATE INDEX CONCURRENTLY",
    "20261023200000_slug_titles_like_confluence.exs" =>
      "rows rewritten and NOT NULL toggled — a manual, batched backfill"
  }

  test "every deploy migration only adds" do
    assert offences() == []
  end

  test "the legacy list names files that still exist" do
    present =
      @deploy_migrations |> Path.join("*.exs") |> Path.wildcard() |> Enum.map(&Path.basename/1)

    assert Enum.sort(Map.keys(@legacy)) -- Enum.sort(present) == []
  end

  describe "what the check catches" do
    test "an index built without CONCURRENTLY" do
      assert [message] =
               offences_in("index.exs", "def change do\n  create index(:pages, [:a])\nend")

      assert message =~ "CONCURRENTLY"
    end

    test "an index on a table the same migration creates" do
      source = """
      def change do
        create table(:things) do
          add :name, :string
        end

        create index(:things, [:name])
      end
      """

      assert offences_in("create.exs", source) == []
    end

    test "a column changed in place" do
      assert [message] =
               offences_in("modify.exs", "def change do\n  modify :a, :text, from: :integer\nend")

      assert message =~ "expand"
    end

    test "rows rewritten in the deploy path" do
      assert [message] =
               offences_in(
                 "backfill.exs",
                 ~s|def up do\n  execute("UPDATE pages SET slug = 'x'")\nend|
               )

      assert message =~ "manual_migrations"
    end

    test "a concurrent index build is what we want" do
      source = """
      @disable_ddl_transaction true

      def change do
        execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON pages (a)")
      end
      """

      assert offences_in("concurrent.exs", source) == []
    end
  end

  defp offences do
    @deploy_migrations
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.reject(&Map.has_key?(@legacy, Path.basename(&1)))
    |> Enum.flat_map(&offences_in(Path.basename(&1), File.read!(&1)))
  end

  defp offences_in(name, source) do
    [
      {index_builds(source), "builds an index without CONCURRENTLY — see docs/operations.md"},
      {in_place_column_changes(source), "changes a column in place — expand, backfill, contract"},
      {row_rewrites(source), "rewrites rows — move it to priv/repo/manual_migrations"}
    ]
    |> Enum.reject(fn {found, _advice} -> found == [] end)
    |> Enum.map(fn {found, advice} -> "#{name}: #{advice}: #{Enum.join(found, ", ")}" end)
  end

  # An index built next to the `create table` that defines it runs against an
  # empty table, where the lock costs nothing.
  defp index_builds(source) do
    cond do
      source =~ ~r/CONCURRENTLY/i ->
        []

      source =~ ~r/\bcreate\s+table\b/i ->
        []

      true ->
        scan(
          source,
          ~r/create(_if_not_exists)?\s+(unique_)?index\s*\(|\bCREATE\s+(UNIQUE\s+)?INDEX\b/i
        )
    end
  end

  # Anchored at the start of a line and requiring a call shape (`modify :a`,
  # `remove(:a)`), so prose in a moduledoc about removing things stays quiet.
  defp in_place_column_changes(source), do: scan(source, ~r/^\s*(modify|remove|rename)\s*[\(:]/m)

  defp row_rewrites(source), do: scan(source, ~r/\b(UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i)

  defp scan(source, pattern) do
    pattern
    |> Regex.scan(source)
    |> Enum.map(fn [match | _] -> match |> String.trim() |> String.slice(0, 40) end)
    |> Enum.uniq()
  end
end
