defmodule ConfluencePhxMirror.Desktop.Migrations.CreateCatalogue do
  @moduledoc """
  The catalogue: what the tool has mirrored, so it can write it out again.

  It lives in `priv/desktop_migrations` rather than beside the modules because a
  release ships `priv` and not `lib`. `:desktop` is the only environment that
  runs it.

  Two columns are text where the server has arrays — `pages.labels` and
  `pages.ancestors` — because SQLite has none. Both are read as lists and never
  filtered on, so `Desktop.Schema.JSONList` converts at the boundary and nothing
  downstream knows the difference.
  """

  use Ecto.Migration

  def change do
    create table(:spaces) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :type, :string, null: false, default: "global"
      add :description, :text
      add :homepage_confluence_id, :integer
      add :external_url, :string
      add :labels, :text, null: false, default: "[]"
      add :icon_path, :string
      add :icon_blob_key, :string
      add :icon_media_type, :string
      add :external_updated_at, :utc_datetime
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:spaces, [:key])

    create table(:pages) do
      add :space_id, references(:spaces, on_delete: :delete_all), null: false
      add :confluence_id, :integer, null: false
      # Not a reference: a page can arrive before its parent, and a broken tree
      # is a rendering problem, not a reason to refuse the row.
      add :parent_id, :integer
      add :type, :string, null: false, default: "page"
      add :status, :string, null: false, default: "current"
      add :subtype, :string
      add :title, :string, null: false
      add :slug, :string
      add :author_name, :string
      add :author_account_id, :string
      add :body_storage, :text
      add :body_export, :text
      add :body_text, :text
      add :labels, :text, null: false, default: "[]"
      add :ancestors, :text, null: false, default: "[]"
      add :version_number, :integer, null: false, default: 1
      add :external_url, :string
      add :external_created_at, :utc_datetime
      add :external_updated_at, :utc_datetime
      add :synced_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pages, [:space_id, :confluence_id])
    create index(:pages, [:parent_id])
    create index(:pages, [:external_updated_at])

    create table(:attachments) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :comment_id, :integer
      add :confluence_id, :string, null: false
      add :filename, :string, null: false
      add :media_type, :string, null: false, default: "application/octet-stream"
      add :byte_size, :integer
      add :version_number, :integer, null: false, default: 1
      add :download_url, :string
      add :blob_key, :string
      add :external_updated_at, :utc_datetime
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:attachments, [:page_id, :confluence_id])

    create table(:comments) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :confluence_id, :integer, null: false
      add :parent_id, :integer
      add :author_name, :string
      add :author_account_id, :string
      add :body_export, :text
      add :body_text, :text
      add :external_url, :string
      add :external_created_at, :utc_datetime
      add :external_updated_at, :utc_datetime
      add :version_number, :integer, null: false, default: 1
      add :synced_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:comments, [:page_id, :confluence_id])
  end
end
