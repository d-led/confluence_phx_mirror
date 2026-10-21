defmodule ConfluencePhxMirror.Repo.Migrations.CreateMirrorCore do
  @moduledoc """
  Content tables of the mirror.

  The mirror is a cache, not a system of record: pages keep the Confluence
  identity (`confluence_id`) plus the last mirrored version. `labels` and
  `ancestors` are denormalised arrays so that label and tree filters stay
  index-only queries against Postgres.
  """
  use Ecto.Migration

  def change do
    create table(:spaces) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :type, :string, null: false, default: "global"
      add :description, :text
      add :homepage_confluence_id, :bigint
      add :external_url, :string
      add :synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:spaces, [:key])

    create table(:pages) do
      add :confluence_id, :bigint, null: false
      add :space_id, references(:spaces, on_delete: :delete_all), null: false
      add :parent_id, references(:pages, on_delete: :nilify_all)
      add :type, :string, null: false, default: "page"
      add :status, :string, null: false, default: "current"
      add :title, :string, null: false
      add :slug, :string, null: false
      add :author_name, :string
      add :author_account_id, :string
      add :body_storage, :text
      add :body_export, :text
      add :body_text, :text
      add :labels, {:array, :string}, null: false, default: []
      add :ancestors, {:array, :bigint}, null: false, default: []
      add :version_number, :integer, null: false, default: 1
      add :version_message, :string
      add :external_url, :string
      add :external_created_at, :utc_datetime
      add :external_updated_at, :utc_datetime
      add :synced_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :search_text, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create unique_index(:pages, [:confluence_id])
    create index(:pages, [:space_id, :type, :title])
    create index(:pages, [:parent_id])
    create index(:pages, [:external_updated_at])
    create index(:pages, [:labels], using: :gin)
    create index(:pages, [:ancestors], using: :gin)

    create table(:labels) do
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:labels, [:name])

    create table(:page_labels) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :label_id, references(:labels, on_delete: :delete_all), null: false
    end

    create unique_index(:page_labels, [:page_id, :label_id])
    create index(:page_labels, [:label_id])

    create table(:attachments) do
      add :confluence_id, :bigint, null: false
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :media_type, :string, null: false, default: "application/octet-stream"
      add :byte_size, :bigint
      add :version_number, :integer, null: false, default: 1
      add :download_url, :string
      add :blob_key, :string
      add :sha256, :string
      add :external_updated_at, :utc_datetime
      add :synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:attachments, [:confluence_id])
    create unique_index(:attachments, [:page_id, :filename])
    create index(:attachments, [:blob_key])

    create table(:comments) do
      add :confluence_id, :bigint, null: false
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :parent_id, references(:comments, on_delete: :nilify_all)
      add :author_name, :string
      add :author_account_id, :string
      add :body_export, :text
      add :body_text, :text
      add :external_url, :string
      add :external_created_at, :utc_datetime
      add :synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:comments, [:confluence_id])
    create index(:comments, [:page_id, :external_created_at])

    create table(:links) do
      add :source_page_id, references(:pages, on_delete: :delete_all), null: false
      add :target_page_id, references(:pages, on_delete: :nilify_all)
      add :target_confluence_id, :bigint
      add :href, :text, null: false
      add :kind, :string, null: false, default: "external"
      add :label, :string
      timestamps(type: :utc_datetime)
    end

    create index(:links, [:source_page_id])
    create index(:links, [:target_page_id])
    create index(:links, [:target_confluence_id])
  end
end
