defmodule ConfluencePhxMirror.Repo.Migrations.MarkRestrictionsGrantedHere do
  @moduledoc """
  Access the mirror grants itself on a restricted page, marked the same way as on
  a space.

  `page_restrictions` is written by the sync and replaced on every run; a row
  with `granted_by_id` set is the mirror's own decision and is left alone. One
  table, so `Authorization` keeps answering page access with the same predicate.
  """
  use Ecto.Migration

  # The index is on a table that is read while a deploy runs, so it is built
  # CONCURRENTLY — which needs both flags (see docs/operations.md).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:page_restrictions) do
      add :granted_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:page_restrictions, [:granted_by_id], concurrently: true)
  end
end
