defmodule ConfluencePhxMirror.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  # The people the site names, which is not the same set as the accounts that
  # sign in here: a byline names somebody who may never hold an account, and a
  # person whose address the site does not share cannot be one at all
  # (`users.email` is required). So the directory of people is its own table,
  # keyed by the one identity the site gives: the account id.
  #
  # Only what the site will tell us is here — the name and the picture. The pages
  # a person wrote stay where they are (the bylines on `pages`) and the groups
  # they belong to stay in `group_members`; this row adds the face.
  def change do
    create table(:people) do
      add :account_id, :string, null: false
      add :display_name, :string
      add :avatar_blob_key, :string
      add :avatar_media_type, :string
      add :avatar_sha256, :string
      add :synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:people, [:account_id])
  end
end
