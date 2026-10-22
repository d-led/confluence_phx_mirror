defmodule ConfluencePhxMirror.Repo.Migrations.AttachmentsConfluenceIdAsText do
  use Ecto.Migration

  # Confluence Cloud hands out attachment ids such as "att164058" next to the
  # numeric ones, so the id has to be text. Pages keep their numeric ids.
  def up do
    alter table(:attachments) do
      modify :confluence_id, :text, from: :integer
    end
  end

  def down do
    alter table(:attachments) do
      modify :confluence_id, :integer, from: :text
    end
  end
end
