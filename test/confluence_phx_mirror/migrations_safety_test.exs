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
      @disable_migration_lock true

      def change do
        execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON pages (a)")
      end
      """

      assert offences_in("concurrent.exs", source) == []
    end

    test "a concurrent index build that keeps the migration lock" do
      # The lock is a transaction on a second connection that stays open until
      # this migration returns, and CONCURRENTLY waits for every open
      # transaction: a fresh database waits on itself.
      source = """
      @disable_ddl_transaction true

      def change do
        execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON pages (a)")
      end
      """

      assert [message] = offences_in("locked.exs", source)
      assert message =~ "@disable_migration_lock"
    end

    test "a rollback is not a deploy step" do
      source =
        ~s|def change do\n  execute("INSERT INTO gate (id) VALUES (true)", "DELETE FROM gate")\nend|

      assert offences_in("gate.exs", source) == []
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
      {concurrently_without_lock_off(source),
       "builds an index CONCURRENTLY under the migration lock — add `@disable_migration_lock true`"},
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

  # CONCURRENTLY waits for every open transaction to finish, and the migration
  # lock is one: it stays open on a second connection until the migration
  # returns, so the build waits for the transaction that waits for the build.
  defp concurrently_without_lock_off(source) do
    cond do
      not (source =~ ~r/CONCURRENTLY/i) -> []
      source =~ ~r/@disable_migration_lock\s+true/ -> []
      true -> ["@disable_migration_lock"]
    end
  end

  # Anchored at the start of a line and requiring a call shape (`modify :a`,
  # `remove(:a)`), so prose in a moduledoc about removing things stays quiet.
  defp in_place_column_changes(source), do: scan(source, ~r/^\s*(modify|remove|rename)\s*[\(:]/m)

  defp row_rewrites(source) do
    scan(deploy_statements(source), ~r/\b(UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i)
  end

  # `execute/2` takes the statement to run and the one that undoes it. Only the
  # first runs during a deploy, so only the first can be a deploy step.
  defp deploy_statements(source) do
    Regex.replace(
      ~r/execute\(\s*("(?:[^"\\]|\\.)*")\s*,\s*"(?:[^"\\]|\\.)*"\s*\)/s,
      source,
      "execute(\\1)"
    )
  end

  defp scan(source, pattern) do
    pattern
    |> Regex.scan(source)
    |> Enum.map(fn [match | _] -> match |> String.trim() |> String.slice(0, 40) end)
    |> Enum.uniq()
  end
end
