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

  @doc """
  Audit entry for a run that just started.

  `site` is the address a reader would open to see the original, `trigger` the
  reason the run happened ("the hourly schedule", "the admin dashboard, by
  jane@acme.com"). Both are what an operator asks first: where, and who.
  """
  def audit_event_started(%__MODULE__{} = run, mode, source_name, opts \\ []) do
    Entry.new(
      "sync.started",
      "sync_run",
      run.id,
      metadata(mode: mode, source: source_name, site: opts[:site], trigger: opts[:trigger])
    )
  end

  @doc "Audit entry for a run that finished, successfully or partially."
  def audit_event_finished(%__MODULE__{} = run, opts \\ []) do
    Entry.new(
      "sync.finished",
      "sync_run",
      run.id,
      metadata(
        mode: run.mode,
        status: run.status,
        stats: run.stats,
        trigger: opts[:trigger]
      )
    )
  end

  @doc "Audit entry for a run that could not even list its spaces."
  def audit_event_failed(%__MODULE__{} = run, message, opts \\ []) do
    Entry.new(
      "sync.failed",
      "sync_run",
      run.id,
      metadata(error: message, mode: run.mode, trigger: opts[:trigger])
    )
  end

  # An entry only carries the facts it has: a run started by nobody in
  # particular has no trigger, and an empty key in the log would read as "none".
  defp metadata(pairs) do
    for {key, value} <- pairs, not is_nil(value), into: %{}, do: {key, value}
  end
end
