defmodule ConfluencePhxMirror.Repo.Migrations.AddLiveEmbedsToPages do
  use Ecto.Migration

  # A page that embeds a database, a board or a deck draws content whose own
  # version moves while the page's does not: somebody adds a row to the database
  # and the page is untouched. This flag is what lets the sync re-read such a page
  # on the live-doc floor instead of waiting for an edit that may never come.
  def change do
    alter table(:pages) do
      add :live_embeds, :boolean, null: false, default: false
    end
  end
end
