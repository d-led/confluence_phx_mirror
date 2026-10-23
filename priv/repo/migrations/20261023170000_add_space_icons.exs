defmodule ConfluencePhxMirror.Repo.Migrations.AddSpaceIcons do
  use Ecto.Migration

  # Confluence gives every space a 48×48 icon — a default tile, an upload, or the
  # owner's avatar for a personal space. The bytes live in the blob store like an
  # attachment; the row keeps what the mirror needs to serve and re-fetch them.
  def change do
    alter table(:spaces) do
      # The upstream path, which Confluence versions, so a changed icon is a
      # changed path and a sync knows when it has to download again.
      add :icon_path, :string
      add :icon_blob_key, :string
      add :icon_media_type, :string
      add :icon_sha256, :string
    end
  end
end
