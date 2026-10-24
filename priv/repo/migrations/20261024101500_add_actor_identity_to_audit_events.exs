defmodule ConfluencePhxMirror.Repo.Migrations.AddActorIdentityToAuditEvents do
  use Ecto.Migration

  # Two rules meet here. The columns are additive, so they may ship in a deploy
  # migration; the indexes are not, because `audit_events` is already taking
  # writes while the new release boots — a plain build would hold them for the
  # length of the scan. Both index statements therefore say CONCURRENTLY, which
  # cannot run inside a transaction, so the transaction and the migration lock
  # go with it (docs/operations.md, "What makes a deploy migration safe").
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Who acted, in the terms a person is asked about months later: the name they
  # showed, the address they signed in with, and the Atlassian account id that
  # survives a rename. `actor_label` stays the one-line label the log has always
  # shown; these are the parts, snapshotted at the time of the action so the row
  # still answers "who" after the account is renamed or deleted.
  def change do
    alter table(:audit_events) do
      add :actor_name, :string
      add :actor_email, :string
      add :actor_account_id, :string
    end

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_actor_email_index " <>
        "ON audit_events (actor_email)",
      "DROP INDEX CONCURRENTLY IF EXISTS audit_events_actor_email_index"
    )

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_actor_account_id_index " <>
        "ON audit_events (actor_account_id)",
      "DROP INDEX CONCURRENTLY IF EXISTS audit_events_actor_account_id_index"
    )
  end
end
