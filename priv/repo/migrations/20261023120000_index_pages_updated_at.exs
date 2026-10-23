defmodule ConfluencePhxMirror.Repo.Migrations.IndexPagesUpdatedAt do
  @moduledoc """
  `max(pages.updated_at)` is how `Mirror.Counters` asks whether the mirror's
  totals are still current: every write moves that column, and an index turns
  the question into a single index probe instead of a scan of every page.
  """
  use Ecto.Migration

  def change do
    create index(:pages, [:updated_at])
  end
end
