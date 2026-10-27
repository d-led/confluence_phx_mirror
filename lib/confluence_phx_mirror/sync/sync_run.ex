defmodule ConfluencePhxMirror.Sync.SyncRun do
  @moduledoc """
  One attempt to bring (part of) the mirror up to date. Sync runs are the
  primary audit record of the ingestion side: mode, status, counters and error.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @type t :: %__MODULE__{}

  @modes ~w(snapshot incremental webhook people)
  @statuses ~w(running succeeded partial failed cancelled)

  schema "sync_runs" do
    field :source, :string
    field :mode, :string
    field :scope, :string
    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :cancel_requested_at, :utc_datetime
    field :stats, :map, default: %{}
    field :error, :string
    # The job Oban was holding while this run did the work, when a job asked for
    # it: a run started from `mix confluence.sync` has none.
    field :job_id, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :source,
      :mode,
      :scope,
      :status,
      :started_at,
      :finished_at,
      :cancel_requested_at,
      :stats,
      :error,
      :job_id
    ])
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
      metadata(
        mode: mode,
        scope: run.scope,
        source: source_name,
        site: opts[:site],
        trigger: opts[:trigger]
      )
    )
  end

  @doc """
  What the run did, in the numbers the dashboard's sync table prints.

  One function for the table and the audit entry, so the two cannot drift: a
  run's numbers are its own window (what the site listed and what of it needed
  fetching), with the mirror's size beside them for scale.
  """
  def summary(%__MODULE__{} = run) do
    stats = run.stats || %{}

    %{
      listed: stats["pages"] || 0,
      changed: stats["changed"] || 0,
      unchanged: stats["unchanged"] || 0,
      in_mirror: stats["total"] || 0,
      attachments: stats["attachments"] || 0,
      errors: length(stats["errors"] || [])
    }
  end

  @doc "Audit entry for a run that finished, successfully or partially."
  def audit_event_finished(%__MODULE__{} = run, opts \\ []) do
    Entry.new(
      "sync.finished",
      "sync_run",
      run.id,
      metadata(
        mode: run.mode,
        scope: run.scope,
        status: run.status,
        duration_ms: duration(run),
        trigger: opts[:trigger],
        indexed: summary(run),
        stats: run.stats
      )
    )
  end

  @doc "Audit entry for a run that could not even list its spaces."
  def audit_event_failed(%__MODULE__{} = run, message, opts \\ []) do
    Entry.new(
      "sync.failed",
      "sync_run",
      run.id,
      metadata(
        error: message,
        mode: run.mode,
        scope: run.scope,
        duration_ms: duration(run),
        trigger: opts[:trigger]
      )
    )
  end

  @doc """
  Audit entry for a run that stopped on request.

  Not a failure: an administrator asked for it, and `by` says which one.
  """
  def audit_event_cancelled(%__MODULE__{} = run, opts \\ []) do
    Entry.new(
      "sync.cancelled",
      "sync_run",
      run.id,
      metadata(mode: run.mode, by: opts[:by], pages: run.stats["pages"], trigger: opts[:trigger])
    )
  end

  @doc """
  Audit entry for a run whose node went away while it was running.

  Nothing asked for this one, so it is recorded as its own event rather than a
  failure an operator would look for in the source's logs.
  """
  def audit_event_abandoned(%__MODULE__{} = run) do
    Entry.new(
      "sync.abandoned",
      "sync_run",
      run.id,
      metadata(mode: run.mode, started_at: DateTime.to_iso8601(run.started_at))
    )
  end

  # An entry only carries the facts it has: a run started by nobody in
  # particular has no trigger, and an empty key in the log would read as "none".
  defp metadata(pairs) do
    for {key, value} <- pairs, not is_nil(value), into: %{}, do: {key, value}
  end
end
