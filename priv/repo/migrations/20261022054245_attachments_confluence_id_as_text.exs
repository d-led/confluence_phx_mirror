defmodule ConfluencePhxMirror.Repo.Migrations.AttachmentsConfluenceIdAsText do
  use Ecto.Migration

  # Confluence Cloud hands out attachment ids such as "att164058" next to the
  # numeric ones, so the id has to be text. Pages keep their numeric ids.
  # SQLite stores a column's declared type but does not enforce it, and it has no
  # `ALTER COLUMN`, so the retype is Postgres's alone; a value written as text
  # reads back as text on either.
  def up do
    if ConfluencePhxMirror.Migration.postgres?() do
      alter table(:attachments) do
        modify :confluence_id, :text, from: :integer
      end
    end
  end

  def down do
    if ConfluencePhxMirror.Migration.postgres?() do
      alter table(:attachments) do
        modify :confluence_id, :integer, from: :text
      end
    end
  end
end
