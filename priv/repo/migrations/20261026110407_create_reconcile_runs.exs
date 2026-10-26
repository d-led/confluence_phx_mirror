defmodule ConfluencePhxMirror.Repo.Migrations.CreateReconcileRuns do
  @moduledoc """
  What each verify pass found, so the review screen can say when it last knew.

  `pages.absent_since` says which pages the site did not list. It cannot say
  whether anybody ever asked: an untouched mirror and a mirror the site agrees
  with look identical, and the screen must not claim the second when it is the
  first. A row per pass is that answer, and the history of them is what makes a
  page that stays absent for weeks visible as a trend rather than a snapshot.

  A pass that never finished leaves `finished_at` NULL, which is how a run
  interrupted by a deploy reads: "started, did not finish" rather than "found
  nothing".
  """
  use Ecto.Migration

  def change do
    create table(:reconcile_runs) do
      add :trigger, :string
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      # What the pass asked and what it found. `listed` counts the spaces whose
      # counts disagreed, which is the number that costs money.
      add :spaces, :integer
      add :agreed, :integer
      add :listed, :integer
      add :absent, :integer
      add :asked, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:reconcile_runs, [:finished_at])

    # The question the screen asks: the newest pass that finished.
    create index(:reconcile_runs, [:inserted_at])
  end
end
