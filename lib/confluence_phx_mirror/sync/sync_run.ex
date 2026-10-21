defmodule ConfluencePhxMirror.Sync.SyncRun do
  @moduledoc """
  One attempt to bring (part of) the mirror up to date. Sync runs are the
  primary audit record of the ingestion side: mode, status, counters and error.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
end
