defmodule ConfluencePhxMirror.Repo.Migrations.AddSearchTextTrigramIndex do
  @moduledoc """
  A word inside another word: the fragment pass of `Mirror.Search.text/2`.

  The text index matches lexeme prefixes, so "escal" finds "Escalation" and
  "scal" finds nothing. That second pass looks for the query *inside* a title or
  body, which is `ILIKE '%…%'` — 390 ms of sequential scan over the pages this
  mirror holds, and hours on a large one. `pg_trgm` answers the same predicate
  from an index: 6 ms, and the index is proportional to the text, not the table.

  `title` has carried a trigram index since the first search migration; this is
  the one for the page text itself. Built CONCURRENTLY so a mirror that is being
  read does not stop answering while it is built.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS pages_search_text_trgm_idx
    ON pages USING gin (search_text gin_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS pages_search_text_trgm_idx"
  end
end
