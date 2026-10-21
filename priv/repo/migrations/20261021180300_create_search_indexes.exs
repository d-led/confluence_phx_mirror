defmodule ConfluencePhxMirror.Repo.Migrations.CreateSearchIndexes do
  @moduledoc """
  Postgres full-text search over the mirror.

  `search_vector` is a stored generated column: the application never has to
  remember to update it, so an imported page is searchable the moment it is
  written. The GIN indexes back CQL-style queries (`text ~`, `title ~`,
  `label =`, `ancestor =`). `pg_trgm` adds typo-tolerant title search.
  """
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    execute """
    ALTER TABLE pages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('simple', coalesce(search_text, '')), 'B')
    ) STORED
    """

    create index(:pages, [:search_vector], using: :gin)
    execute "CREATE INDEX pages_title_trgm_idx ON pages USING gin (title gin_trgm_ops)"
  end

  def down do
    execute "DROP INDEX IF EXISTS pages_title_trgm_idx"
    drop index(:pages, [:search_vector])
    execute "ALTER TABLE pages DROP COLUMN IF EXISTS search_vector"
  end
end
