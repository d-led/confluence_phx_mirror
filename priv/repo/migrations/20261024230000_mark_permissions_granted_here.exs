defmodule ConfluencePhxMirror.Repo.Migrations.MarkPermissionsGrantedHere do
  @moduledoc """
  Access this mirror grants itself, in the same table as the access it replays.

  `space_permissions` is the sync's: every run replaces a space's rows wholesale.
  An operator sometimes has to let somebody read a space the site narrows to
  another group, and there is nothing to change on the Confluence side (the API
  is write-only for space permissions, and the sync account is usually not a
  space administrator). So a granted row lives beside the mirrored ones and is
  marked by who granted it — one table, so every access rule that already reads
  it sees the grant without learning a second concept.

  `replace_space_permissions/2` deletes only the rows with a null `granted_by_id`:
  a grant here is never removed by a sync.
  """
  use Ecto.Migration

  def change do
    alter table(:space_permissions) do
      add :granted_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:space_permissions, [:granted_by_id])
  end
end
