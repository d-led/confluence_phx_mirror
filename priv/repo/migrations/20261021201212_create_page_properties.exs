defmodule ConfluencePhxMirror.Repo.Migrations.CreatePageProperties do
  @moduledoc """
  Key/value pairs extracted from `pageproperties` macros.

  Confluence resolves these macros in the browser, so the mirror reads them from
  the page's storage format during sync and stores them as data. That is what
  makes the mirror's own "page properties report" static and searchable.
  """
  use Ecto.Migration

  def change do
    create table(:page_properties) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:page_properties, [:page_id, :key])
  end
end
