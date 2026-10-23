defmodule ConfluencePhxMirror.Repo.Migrations.AddSoftDeleteToSpacesAndComments do
  use Ecto.Migration

  # Spaces and comments join pages in being *trashed* rather than deleted: a
  # space removed in Confluence, or a comment removed from a page, leaves its row
  # behind so the audit trail stays readable and an administrator can purge it
  # deliberately (`ConfluencePhxMirror.Trash`). Reads filter on `deleted_at`,
  # exactly like pages.
  def change do
    alter table(:spaces) do
      add :deleted_at, :utc_datetime
    end

    alter table(:comments) do
      add :deleted_at, :utc_datetime
    end
  end
end
