defmodule ConfluencePhxMirror.Jobs do
  @moduledoc """
  Oban's own rows, in every state — the half the queue table does not show.

  The dashboard lists the syncs *waiting* their turn, because a queued sync is
  something an operator can still prevent. This is the other half: all of Oban's
  states, `executing` included. That one matters because a job whose node died
  stays `executing` for ever — the queue never lists it, nothing reports it
  finishing, and it keeps one of the queue's slots busy. Deploys make those, so
  an operator needs to see them.

  Oban is not the sync's private scheduler: anything the mirror wants off the
  request path can be a job. So nothing here knows what a sync is. What a job is
  *doing* comes from the record that job writes, through
  `ConfluencePhxMirror.Jobs.Progress` — a sync run is the first such record (see
  `@records`), and the next one is a schema with a `job_id`, an entry there, and
  a `Progress` implementation. The page over this module does not change.

  Cancelling is `Oban.cancel_all_jobs/1` with the state in the query, the same
  way a queued job is dropped: a job that finished between the page rendering
  and the click is left alone rather than overwritten.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Jobs.Progress
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.Log
  alias ConfluencePhxMirror.Sync.SyncRun
  alias Oban.Job

  # Waiting for a slot, for its schedule, or for its next attempt, and — the
  # interesting one — running: a job in any of these has not reached an outcome.
  @unfinished ~w(executing available scheduled retryable)
  @states @unfinished ++ ~w(completed cancelled discarded)

  @limit 200

  # The records a job can be the executor of, each carrying the job's id. One
  # entry today; this list is what a second feature adds to.
  @records [SyncRun]

  @doc "The states a job can be in: what the page offers as a filter."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  The states in which a job has not reached an outcome, so stopping it is
  possible and has a meaning.
  """
  @spec unfinished_states() :: [String.t()]
  def unfinished_states, do: @unfinished

  @doc """
  The jobs Oban holds, newest first.

  An unknown state reads as "all": the filter is a parameter a reader can edit,
  and a page that refuses to show the table because of a typo is worse than a
  page that shows everything.
  """
  @spec list(String.t(), pos_integer()) :: [Job.t()]
  def list(state \\ "all", limit \\ @limit) do
    Job
    |> by_state(state)
    |> order_by([j], desc: j.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp by_state(query, state) when state in @states, do: where(query, [j], j.state == ^state)
  defp by_state(query, _every_state), do: query

  @doc """
  What each of `job_ids` is doing, keyed by job id — absent where it is doing
  nothing yet.

  A job that is only queued has written no record, and a job whose worker writes
  none never will; both are absent from the result. Where several records could
  answer for one job, the newest wins: a retried job keeps the record of its last
  attempt, which is the one an operator asks about.
  """
  @spec work_of([integer()]) :: %{integer() => struct()}
  def work_of([]), do: %{}

  def work_of(job_ids) do
    @records
    |> Enum.flat_map(&latest_per_job(&1, job_ids))
    |> Map.new(&{&1.job_id, &1})
  end

  defp latest_per_job(queryable, job_ids) do
    from(r in queryable,
      where: r.job_id in ^job_ids,
      distinct: r.job_id,
      order_by: [asc: r.job_id, desc: r.id]
    )
    |> Repo.all()
  end

  @doc """
  What a job has done, in the record's own words — `nil` when it wrote no record.

  The page hands this and `ConfluencePhxMirror.Jobs.Progress` straight to the
  template, so a job from a feature that does not exist yet reads the same way a
  sync does.
  """
  @spec progress(struct() | nil) :: String.t() | nil
  def progress(nil), do: nil
  def progress(record), do: Progress.summary(record)

  @doc """
  Stops a job, whether it is waiting or running.

  Returns `{:error, :settled}` when there is nothing to stop — the job already
  finished, was already cancelled, or is gone. Oban marks the row `cancelled`
  and its pruner takes it a minute later (the configured `Pruner` default); the
  audit entry is the record that outlives it, and it says who stopped the job.
  """
  @spec cancel(integer(), Audit.actor()) :: {:ok, Job.t()} | {:error, :settled}
  def cancel(job_id, actor) when is_integer(job_id) do
    case Repo.get(Job, job_id) do
      %Job{state: state} = job when state in @unfinished -> cancel_unfinished(job, actor)
      _settled_or_missing -> {:error, :settled}
    end
  end

  defp cancel_unfinished(job, actor) do
    query = from(j in Job, where: j.id == ^job.id and j.state in ^@unfinished)

    case Oban.cancel_all_jobs(query) do
      {:ok, 1} ->
        Log.add(:warn, "job #{job.id} (#{worker_name(job)}) was cancelled while #{job.state}")
        Audit.log(actor, audit_event(job))

        {:ok, Repo.get(Job, job.id)}

      {:ok, 0} ->
        {:error, :settled}
    end
  end

  defp audit_event(job) do
    Audit.Entry.new("job.cancelled", "job", job.id, %{
      worker: job.worker,
      queue: job.queue,
      state: job.state,
      attempts: job.attempt
    })
  end

  @doc "The worker's own name, without the application prefix: the last segment."
  @spec worker_name(Job.t()) :: String.t()
  def worker_name(%Job{worker: worker}), do: worker |> String.split(".") |> List.last()
end
