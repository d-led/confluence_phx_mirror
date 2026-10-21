defmodule ConfluencePhxMirror.Repo.Migrations.CreateGroupMembers do
  use Ecto.Migration

  def change do
    create table(:group_members) do
      # The name Confluence reports, plus a lower-cased key for matching:
      # Confluence treats group names case-insensitively.
      add :group_name, :string, null: false
      add :group_key, :string, null: false
      # Either the lower-cased e-mail address or the account id, whichever
      # Confluence exposes for this member.
      add :subject_key, :string, null: false
      add :email, :string
      add :account_id, :string
      add :display_name, :string

      timestamps(type: :utc_datetime)
    end

    create index(:group_members, [:subject_key])

    create unique_index(:group_members, [:group_key, :subject_key], name: :group_members_unique)
  end
end
