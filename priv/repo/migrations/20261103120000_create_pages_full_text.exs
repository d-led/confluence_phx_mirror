defmodule ConfluencePhxMirror.Repo.Migrations.CreatePagesFullText do
  use Ecto.Migration

  # Postgres answers full-text from the generated `pages.search_vector` column and
  # the GIN indexes built around it (see the migration that added them), so this
  # one has nothing to add there. A build whose store is a file needs the index
  # that column would have been: FTS5.
  #
  # `content='pages'` keeps the text in one place — the index stores positions and
  # a copy of nothing — so the two cannot disagree after an update; the triggers
  # are what keep the positions in step with the rows, and they fire for Ecto
  # updates, `update_all`, and the purge's delete alike.
  #
  # A million pages live or die by these three triggers being right, so they are
  # the canonical external-content trio: insert one row, delete-then-insert on
  # update (`'delete'` is FTS5's spelling of "drop this rowid's tokens"), delete
  # on removal.

  def up do
    if ConfluencePhxMirror.Migration.postgres?() do
      :ok
    else
      execute("""
      CREATE VIRTUAL TABLE pages_fts USING fts5(
        title,
        body_text,
        content='pages',
        content_rowid='id',
        tokenize="unicode61 remove_diacritics 2"
      )
      """)

      execute("""
      CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
        INSERT INTO pages_fts(rowid, title, body_text)
        VALUES (new.id, new.title, new.body_text);
      END
      """)

      execute("""
      CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
        INSERT INTO pages_fts(pages_fts, rowid, title, body_text)
        VALUES ('delete', old.id, old.title, old.body_text);
      END
      """)

      execute("""
      CREATE TRIGGER pages_fts_au AFTER UPDATE OF title, body_text ON pages BEGIN
        INSERT INTO pages_fts(pages_fts, rowid, title, body_text)
        VALUES ('delete', old.id, old.title, old.body_text);
        INSERT INTO pages_fts(rowid, title, body_text)
        VALUES (new.id, new.title, new.body_text);
      END
      """)

      # What is already in the catalogue gets indexed now rather than on its next
      # write: a catalogue that has been mirrored for months would otherwise be
      # searchable only up to the day the app was updated.
      execute("INSERT INTO pages_fts(pages_fts) VALUES('rebuild')")
    end
  end

  def down do
    if ConfluencePhxMirror.Migration.postgres?() do
      :ok
    else
      execute("DROP TRIGGER IF EXISTS pages_fts_au")
      execute("DROP TRIGGER IF EXISTS pages_fts_ad")
      execute("DROP TRIGGER IF EXISTS pages_fts_ai")
      execute("DROP TABLE IF EXISTS pages_fts")
    end
  end
end
