defmodule ConfluencePhxMirror.Repo.Migrations.CreateSiteSettings do
  use Ecto.Migration

  # What the site says about itself, rather than about its content: the title it
  # goes by, the language a reader is defaulted to, and its time zone. One row —
  # a mirror serves one site — so the primary key is a constant.
  def change do
    create table(:site_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :title, :string
      add :locale, :string
      add :timezone, :string
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
