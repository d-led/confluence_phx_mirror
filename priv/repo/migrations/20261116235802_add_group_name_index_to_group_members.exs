defmodule ConfluencePhxMirror.Repo.Migrations.AddGroupNameIndexToGroupMembers do
  use Ecto.Migration

  # Both flags are needed for `CREATE INDEX CONCURRENTLY`, and a deploy runs this
  # while the previous release is still serving: `disable_ddl_transaction` keeps
  # the build out of a transaction, and `disable_migration_lock` keeps the
  # migrator's advisory-lock transaction off the second connection, because
  # CONCURRENTLY waits for every open transaction — including the one waiting for
  # this migration to return.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The admin screens offer the groups the last sync read: the users screen lists
  # them, and the permissions dialog matches a typed term against them on every
  # keystroke. That read is `SELECT DISTINCT group_name FROM group_members`, and
  # the indexes on the table led with `subject_key`, `group_key` or `account_id` —
  # so it was a sequential scan of every membership the mirror holds. With an
  # index on the name the same query is answered from the index.
  def change do
    ConfluencePhxMirror.Migration.build_index(
      "group_members_group_name_index",
      :group_members,
      [:group_name]
    )
  end
end
