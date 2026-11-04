defmodule ConfluencePhxMirror.Desktop.Jobs do
  @moduledoc """
  The tool's mirror, as the jobs the mirror already has.

  A run is a `SpaceWorker` on the `sync` queue: the same worker an administrator
  presses *Sync* for on a deployment, doing the same work through `Sync.run/2` —
  one row in `sync_runs`, the gate that keeps two runs apart, retries while the
  site is flaky, and a cancel that stops at the next page.

  The tool used to have a second copy of that loop: a task under a supervisor,
  writing the same rows in the same order. It could not be cancelled, left no
  record of itself, and died with the window — three failures that all came from
  being a copy. So the copy is gone: this module enqueues, reads the run, and
  asks it to stop; the writing stays the server's, unchanged.

  What is the tool's own is the *decision*: which spaces a person chose, and the
  words a window says while the queue works. One run at a time is the queue's
  (`queues: [sync: 1]` in `config/desktop.exs`), not a flag kept here.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{SpaceWorker, SyncRun}
  alias Oban.Job

  # Who asked. A run's trigger is the first thing an operator reads, and in a
  # window there is nobody to name: the person is whoever is at the machine.
  @actor {:system, "the desktop tool"}
  @trigger "the desktop tool"

  # The states in which a job is still going to be performed.
  @waiting ~w(available scheduled retryable executing)

  # How Oban names a worker in `oban_jobs.worker`: the module without the
  # `Elixir.` prefix.
  @worker inspect(SpaceWorker)

  @type state :: :idle | :queued | :running | :done | :cancelled | :error

  @typedoc """
  What the mirror screen shows: the run the tool last asked for, and whether the
  queue still holds more of them.
  """
  @type status :: %{
          state: state(),
          run_id: integer() | nil,
          label: String.t() | nil,
          done: non_neg_integer(),
          queued: non_neg_integer(),
          error: String.t() | nil
        }

  @doc """
  Mirrors `space_keys`, in the order given, under `label` in the window's words.

  Answers `{:error, :busy}` while a run is going or jobs are waiting — a second
  start would only queue behind the first, and a button that says "started" while
  nothing moves is worse than one that says "not yet". `:nothing_to_do` is a
  start with no space in it, `:list_loading` is a start while the space list is
  still being fetched (nothing is known about any key yet, so nothing may be
  acted on), and `{:unknown_space, key}` is a space the site does not list:
  recording that one would leave the workspace configured for a space that is not
  there, and running it would invent an empty one.

  `remember: false` is a bulk run: it copies what the workspace is configured for
  and does not decide the configuration. A single space *is* that decision, and is
  recorded where a whole-site sync reads it (`Sync.SpaceScope`) — copying
  everything the site lists used to add every one of those keys, which is how a
  workspace set up for one space ended up holding a hundred others.
  """
  @spec start_mirror([String.t() | nil], String.t(), keyword()) ::
          {:ok, :started}
          | {:error,
             :busy | :nothing_to_do | :list_loading | {:unknown_space, String.t()} | term()}
  def start_mirror(space_keys, _label, opts \\ []) do
    keys = space_keys |> Enum.reject(&blank?/1) |> Enum.uniq()

    cond do
      keys == [] -> {:error, :nothing_to_do}
      spaces() == :loading -> {:error, :list_loading}
      unknown = Enum.find(keys, &(not known?(&1))) -> {:error, {:unknown_space, unknown}}
      going?() -> {:error, :busy}
      true -> enqueue(keys, Keyword.get(opts, :remember, true))
    end
  end

  @doc """
  What the mirror is doing, read from the record rather than remembered here.

  A run left `running` by a node that is gone is settled first
  (`Sync.abandon_abandoned_runs/0`): a window that shows a run nobody is doing
  has no way past it.
  """
  @spec status() :: status()
  def status do
    Sync.abandon_abandoned_runs()

    run = latest_run()
    waiting = queued()

    %{
      state: state(run, waiting),
      run_id: run && run.id,
      label: label(run),
      done: pages(run),
      queued: waiting,
      error: run && run.error
    }
  end

  @doc """
  Stops what the tool started: the jobs still waiting, and the run in flight.

  Both, and in that order: emptying the queue first is what makes "stop" mean
  stop — a bulk run of a hundred spaces would otherwise cancel the one in flight
  and start the next one a moment later.

  Answers how many things were stopped. A run stops at its next page — the same
  cancel an administrator's screen asks for — so the answer is "asked", and the
  row it leaves says the outcome.
  """
  @spec cancel() :: {:ok, non_neg_integer()}
  def cancel do
    waiting = cancel_queued()

    stopped =
      case running_run() do
        %SyncRun{id: id} ->
          _ = Sync.cancel(id, @actor)
          1

        nil ->
          0
      end

    {:ok, waiting + stopped}
  end

  # ---------------------------------------------------------------------------
  # Queueing
  # ---------------------------------------------------------------------------

  # Whether the site lists this space. The window already holds the list — it is
  # what the picker draws — so the question is answered from memory; a list that
  # never arrived is asked for once, because a refusal must be about the site and
  # not about what the window happened to have cached.
  defp known?(key) do
    case spaces() do
      {:ok, spaces} -> Enum.any?(spaces, &(&1.key == key))
      _not_known_yet -> false
    end
  end

  defp spaces do
    case ConfluencePhxMirror.Desktop.Spaces.list() do
      {:ok, spaces} -> {:ok, spaces}
      _loading_or_failed -> Source.source().spaces([])
    end
  end

  defp enqueue(keys, remember?) do
    if remember?, do: Enum.each(keys, &Sync.SpaceScope.add(&1, Audit.system_actor()))

    results =
      Enum.map(keys, fn key ->
        Sync.enqueue(SpaceWorker, %{"space_key" => key, "trigger" => @trigger})
      end)

    # One job that would not go is no reason to keep the others out of the
    # queue; it is an error only when none of them went.
    if Enum.any?(results, &match?({:ok, _job}, &1)) do
      {:ok, :started}
    else
      Enum.find_value(results, {:ok, :started}, &error_of/1)
    end
  end

  defp error_of({:error, reason}), do: {:error, reason}
  defp error_of(_ok), do: nil

  defp cancel_queued do
    Job
    |> where([j], j.worker == ^@worker and j.state in ^@waiting)
    |> select([j], j.id)
    |> Repo.all()
    |> Enum.count(fn id -> match?({:ok, _job}, Sync.cancel_queued(id, @actor)) end)
  end

  # ---------------------------------------------------------------------------
  # Reading it back
  # ---------------------------------------------------------------------------

  defp going?, do: running_run() != nil or queued() > 0

  defp running_run do
    Repo.one(
      from r in SyncRun,
        where: r.status == "running",
        order_by: [desc: r.started_at],
        limit: 1
    )
  end

  defp latest_run do
    Repo.one(from r in SyncRun, order_by: [desc: r.started_at], limit: 1)
  end

  defp queued do
    Repo.aggregate(
      from(j in Job, where: j.worker == ^@worker and j.state in ^@waiting),
      :count
    )
  end

  # A run in flight outranks one waiting; a run that finished outranks nothing
  # only while the queue is empty — after a bulk start the window says "queued"
  # between two spaces, not "done".
  defp state(%SyncRun{status: "running"}, _queued), do: :running
  defp state(_run, queued) when queued > 0, do: :queued
  defp state(%SyncRun{status: status}, _queued) when status in ~w(succeeded partial), do: :done
  defp state(%SyncRun{status: "cancelled"}, _queued), do: :cancelled
  defp state(%SyncRun{status: "failed"}, _queued), do: :error
  defp state(_run, _queued), do: :idle

  # A run's scope is the space it read; a run with no scope is the site's.
  defp label(nil), do: nil
  defp label(%SyncRun{scope: scope}) when is_binary(scope) and scope != "", do: scope
  defp label(%SyncRun{}), do: "the site"

  defp pages(nil), do: 0
  defp pages(%SyncRun{stats: stats}), do: (stats || %{})["pages"] || 0

  defp blank?(value), do: value in [nil, ""]
end
