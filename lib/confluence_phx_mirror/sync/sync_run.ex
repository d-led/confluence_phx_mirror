defmodule ConfluencePhxMirror.Sync.SyncRun do
  @moduledoc """
  One attempt to bring (part of) the mirror up to date. Sync runs are the
  primary audit record of the ingestion side: mode, status, counters and error.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @type t :: %__MODULE__{}

  @modes ~w(snapshot incremental webhook)
  @statuses ~w(running succeeded partial failed)

  schema "sync_runs" do
    field :source, :string
    field :mode, :string
    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :stats, :map, default: %{}
    field :error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:source, :mode, :status, :started_at, :finished_at, :stats, :error])
    |> validate_required([:source, :mode, :status, :started_at])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
  end

  def duration(%__MODULE__{started_at: started_at, finished_at: finished_at})
      when is_nil(started_at) or is_nil(finished_at),
      do: nil

  def duration(%__MODULE__{started_at: started_at, finished_at: finished_at}) do
    DateTime.diff(finished_at, started_at, :millisecond)
  end

  @doc "Audit entry for a run that just started."
  def audit_event_started(%__MODULE__{} = run, mode, source_name) do
    Entry.new("sync.started", "sync_run", run.id, %{mode: mode, source: source_name})
  end

  @doc "Audit entry for a run that finished, successfully or partially."
  def audit_event_finished(%__MODULE__{} = run) do
    Entry.new("sync.finished", "sync_run", run.id, %{status: run.status, stats: run.stats})
  end

  @doc "Audit entry for a run that could not even list its spaces."
  def audit_event_failed(%__MODULE__{} = run, message) do
    Entry.new("sync.failed", "sync_run", run.id, %{error: message})
  end
end
