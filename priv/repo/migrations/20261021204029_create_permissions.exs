defmodule ConfluencePhxMirror.Repo.Migrations.CreatePermissions do
  use Ecto.Migration

  def change do
    create table(:space_permissions) do
      add :space_id, references(:spaces, on_delete: :delete_all), null: false
      add :operation, :string, null: false, default: "read"
      add :subject_type, :string, null: false
      add :subject_key, :string

      timestamps(type: :utc_datetime)
    end

    create index(:space_permissions, [:space_id, :operation])

    create unique_index(
             :space_permissions,
             [:space_id, :operation, :subject_type, :subject_key],
             name: :space_permissions_unique
           )

    create table(:page_restrictions) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :operation, :string, null: false, default: "read"
      add :subject_type, :string, null: false
      add :subject_key, :string

      timestamps(type: :utc_datetime)
    end

    create index(:page_restrictions, [:page_id, :operation])

    create unique_index(
             :page_restrictions,
             [:page_id, :operation, :subject_type, :subject_key],
             name: :page_restrictions_unique
           )

    alter table(:users) do
      # The bridge between a mirror account and Confluence: restrictions name
      # accounts and groups, so a reader needs the same identifiers here.
      add :confluence_account_id, :string
      add :groups, {:array, :string}, null: false, default: []
    end
  end
end
