defmodule ConfluencePhxMirror.Repo.Migrations.AddSyncCancellation do
  use Ecto.Migration

  # A cancel is a request, not a command: the run notices it at the next safe
  # boundary and stops there, so the column records "someone asked" while the
  # status keeps saying "running" until it actually stops.
  def change do
    alter table(:sync_runs) do
      add :cancel_requested_at, :utc_datetime
    end
  end
end
