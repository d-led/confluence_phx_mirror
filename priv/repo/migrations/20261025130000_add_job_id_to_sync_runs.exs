defmodule ConfluencePhxMirror.Repo.Migrations.AddJobIdToSyncRuns do
  @moduledoc """
  The Oban job a run came from.

  A run is what a sync did; the job is what Oban held while it did it. They were
  two records nobody could join, which made "what is this job doing?" a question
  only a timestamp could answer. Rows written before this column have no job to
  point at, which is what `NULL` says.
  """
  use Ecto.Migration

  # Built while a deploy is serving readers, so it is CONCURRENTLY — which needs
  # both flags (see docs/operations.md).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:sync_runs) do
      add :job_id, :bigint
    end

    create index(:sync_runs, [:job_id], concurrently: true)
  end
end
