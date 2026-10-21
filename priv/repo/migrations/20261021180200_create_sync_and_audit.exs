defmodule ConfluencePhxMirror.Repo.Migrations.CreateSyncAndAudit do
  @moduledoc """
  Audit trail of the mirror: every sync run, every webhook delivery and every
  content / account mutation is recorded here.
  """
  use Ecto.Migration

  def change do
    create table(:sync_runs) do
      add :source, :string, null: false
      add :mode, :string, null: false
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :stats, :map, null: false, default: %{}
      add :error, :text
      timestamps(type: :utc_datetime)
    end

    create index(:sync_runs, [:started_at])
    create index(:sync_runs, [:status])

    create table(:audit_events) do
      add :actor_type, :string, null: false
      add :actor_id, :string
      add :actor_label, :string
      add :action, :string, null: false
      add :entity_type, :string
      add :entity_id, :string
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:audit_events, [:inserted_at])
    create index(:audit_events, [:action])
    create index(:audit_events, [:entity_type, :entity_id])

    create table(:webhook_deliveries) do
      add :event_type, :string
      add :payload, :map, null: false, default: %{}
      add :signature_valid, :boolean, null: false, default: false
      add :status, :string, null: false, default: "received"
      add :error, :text
      add :received_at, :utc_datetime, null: false
      add :processed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:webhook_deliveries, [:received_at])
    create index(:webhook_deliveries, [:status])
  end
end
