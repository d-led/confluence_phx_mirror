defmodule ConfluencePhxMirror.Repo.Migrations.CreateMirrorSites do
  use Ecto.Migration

  def change do
    create table(:mirror_sites, primary_key: false) do
      add :id, :integer, primary_key: true
      add :key, :string, null: false
      add :base_url, :string
      add :source, :string
      add :kind, :string, null: false, default: "demo"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mirror_sites, [:key])
  end
end
