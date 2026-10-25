defmodule ConfluencePhxMirror.Repo.Migrations.IndexCommentSearch do
  @moduledoc """
  Comments are part of what a reader searches.

  A comment is written by the sync with two columns the mirror already keeps:
  the author and the plain text of the exported body. The text index is an
  expression over those two columns rather than a stored `search_vector`: a
  generated column would have rewritten the whole table under the deploy that
  added it, and the expression index gives the same answer while only building
  an index. Nothing has to be re-read from Confluence for this to work.

  That is the only index. A second, trigram index on comment text would be a
  second `CREATE INDEX CONCURRENTLY` on `comments` in the same migration, and
  two concurrent builds on one table deadlock against each other: the first
  waits for the other's snapshot while the other waits for the table's
  ShareUpdateExclusiveLock. Without the trigram index, a word fragment inside a
  comment word is not found; a word prefix is, which is what the comment search
  promises.

  Built CONCURRENTLY so a mirror that is being read keeps answering; the query
  in `Mirror.Search` writes the vector expression exactly as it is written
  here, because Postgres only uses an expression index for an identical
  expression.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS comments_search_vector_idx
    ON comments USING gin (
      to_tsvector('simple', coalesce(author_name, '') || ' ' || coalesce(body_text, ''))
    )
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS comments_search_vector_idx"
  end
end
