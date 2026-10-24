defmodule ConfluencePhxMirror.Repo.Migrations.AddCommentAttachmentsAndDetailSync do
  use Ecto.Migration

  # A deploy migration runs while the previous release is still serving, so it
  # only adds: new nullable columns, and index builds that do not block writes.
  #
  # Both flags are needed for `CREATE INDEX CONCURRENTLY`. `disable_ddl_transaction`
  # keeps the build out of a transaction; `disable_migration_lock` keeps the
  # migrator's own advisory-lock transaction off the second connection, because
  # CONCURRENTLY waits for every open transaction — including the one that is
  # waiting for this migration to return. Without it a fresh database sits on the
  # index build until the pool's ownership timeout kills the run (measured: 119.5s,
  # then `{:error, :rollback}`), which is how CI fails on an empty schema.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # A file can hang off a page or off one of its comments — a screenshot pasted
  # into a comment belongs to the comment, and Confluence's own download path
  # names the comment as the owner. The column is what lets the mirror keep the
  # two apart: the page's file list stays the page's, and a comment that goes
  # away takes its files with it.
  #
  # `pages.details_synced_at` records the last time a page's comments,
  # attachments and restrictions were read. Without it a page whose details a
  # run missed could never be asked about again: comments are not part of the
  # page's version, so nothing else ever points back at them.
  def change do
    alter table(:attachments) do
      add :comment_id, references(:comments, on_delete: :delete_all)
    end

    alter table(:pages) do
      add :details_synced_at, :utc_datetime
    end

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS attachments_comment_id_index " <>
        "ON attachments (comment_id)",
      "DROP INDEX CONCURRENTLY IF EXISTS attachments_comment_id_index"
    )

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS pages_details_synced_at_index " <>
        "ON pages (details_synced_at)",
      "DROP INDEX CONCURRENTLY IF EXISTS pages_details_synced_at_index"
    )
  end
end
