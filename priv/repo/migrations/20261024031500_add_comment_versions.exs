defmodule ConfluencePhxMirror.Repo.Migrations.AddCommentVersions do
  use Ecto.Migration

  # A comment has a version of its own: editing one bumps it, and an operator
  # asking "which version is this mirror showing?" needs an answer for comments
  # the way they have one for pages and attachments.
  #
  # Two nullable columns on an existing table: nothing is rewritten, and the
  # previous release keeps writing rows without them.
  def change do
    alter table(:comments) do
      add :version_number, :integer
      add :external_updated_at, :utc_datetime
    end
  end
end
