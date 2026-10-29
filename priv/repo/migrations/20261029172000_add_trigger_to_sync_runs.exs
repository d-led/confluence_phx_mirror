defmodule ConfluencePhxMirror.Repo.Migrations.AddTriggerToSyncRuns do
  use Ecto.Migration

  # Why a run happened — "the hourly schedule", "the admin dashboard, by
  # jane@acme.com" — is a property of the run, not one of its counters. It used
  # to ride inside `stats`, which `finish_run/5` replaces wholesale, so the
  # finish had to put it back and the screens had to know to look inside a JSON
  # blob for it.
  #
  # New rows write the column. Rows written before it existed keep their copy in
  # `stats`, and `SyncRun.trigger/1` reads either; moving them across rewrites
  # rows, so it is a manual migration.
  def change do
    alter table(:sync_runs) do
      add :trigger, :string
    end
  end
end
