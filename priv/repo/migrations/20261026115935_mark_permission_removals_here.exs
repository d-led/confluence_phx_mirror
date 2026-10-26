defmodule ConfluencePhxMirror.Repo.Migrations.MarkPermissionRemovalsHere do
  @moduledoc """
  Access an administrator takes away here, marked the way a grant is.

  The sync replaces the rows it wrote, so "this identity may no longer read
  this" needs a row of the mirror's own to survive the next run. `revoked_by_id`
  is that mark: one column, so `Authorization` keeps asking one table per level,
  and a row can never be both a grant and a removal.
  """
  use Ecto.Migration

  # Both tables are read while a deploy runs, so the indexes are built
  # CONCURRENTLY — which needs both flags (see docs/operations.md).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:space_permissions) do
      add :revoked_by_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:page_restrictions) do
      add :revoked_by_id, references(:users, on_delete: :nilify_all)
    end

    create constraint(:space_permissions, :space_permissions_one_overlay,
             check: "granted_by_id IS NULL OR revoked_by_id IS NULL"
           )

    create constraint(:page_restrictions, :page_restrictions_one_overlay,
             check: "granted_by_id IS NULL OR revoked_by_id IS NULL"
           )

    create index(:space_permissions, [:revoked_by_id], concurrently: true)
    create index(:page_restrictions, [:revoked_by_id], concurrently: true)
  end
end
