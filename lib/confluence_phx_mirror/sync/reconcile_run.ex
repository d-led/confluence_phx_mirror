defmodule ConfluencePhxMirror.Sync.ReconcileRun do
  @moduledoc """
  One verify pass: what it asked the site and what it found.

  `ConfluencePhxMirror.Sync.Reconcile` writes one of these per pass, because
  "nothing is absent" is only a fact *after* somebody asked. Without it the
  review screen cannot tell an untouched mirror from one the site agrees with,
  and it must not guess.

  `finished_at` is NULL while a pass runs, and it is what makes the pass
  resumable: the observations it has written are the spaces it may skip, and the
  next attempt continues this row instead of starting another (`resume_or_start/1`).
  A pass that is never finished within a day is abandoned rather than continued,
  so a row with a NULL `finished_at` is either running now or was interrupted.
  """

  use Ecto.Schema

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.ReconcileObservation

  # How long an unfinished pass is worth continuing. A pass is a statement about
  # the site now; one that has been lying half-done for longer than a day is not,
  # and starting again is the honest answer.
  @resume_window_seconds 24 * 60 * 60

  # Where a settled space is announced, so an open screen can show the facts
  # arriving instead of waiting for the pass to end.
  @topic "reconcile_run"

  @type t :: %__MODULE__{}

  schema "reconcile_runs" do
    field :trigger, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :spaces, :integer
    field :agreed, :integer
    field :listed, :integer
    field :absent, :integer
    field :asked, :integer

    timestamps(type: :utc_datetime)
  end

  @doc "Records a pass that has just begun."
  @spec start(map()) :: t()
  def start(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.change(Map.merge(%{started_at: now()}, attrs))
    |> Repo.insert!()
  end

  @doc """
  The unfinished pass a new attempt continues, or a fresh one.

  Continuing is what makes a long pass safe to interrupt: the spaces the last
  attempt recorded are done and are not asked about again. Only one pass can be
  in flight (`ReconcileWorker`'s uniqueness), so an unfinished pass is this
  pass's own earlier attempt.
  """
  @spec resume_or_start(map()) :: t()
  def resume_or_start(attrs) do
    open() || start(attrs)
  end

  @doc """
  The pass that is still running, or `nil`.

  Older than the resume window, an unfinished pass is abandoned rather than
  continued: its facts are as old as its start.
  """
  @spec open() :: t() | nil
  def open do
    from(r in __MODULE__,
      where: is_nil(r.finished_at) and r.started_at >= ^begun_since(),
      order_by: [desc: r.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Topic a settled space and a finished pass are announced on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Records what the pass learned about one space.

  Writing the row is the promise that the space is settled: the pass marks
  before it records, so a row never stands for work that did not happen.
  `on_conflict: :nothing` keeps a retried space from being recorded twice.

  The row is announced on `topic/0`, which is what lets `/admin/upstream` show the
  facts as they arrive rather than after the last space.
  """
  @spec observe(t(), Space.t(), map()) :: ReconcileObservation.t()
  def observe(%__MODULE__{} = run, %Space{} = space, fact) do
    observation =
      %ReconcileObservation{}
      |> Ecto.Changeset.change(%{
        run_id: run.id,
        space_id: space.id,
        verdict: to_string(fact.verdict),
        asked: fact.asked,
        counted: fact.counted,
        named: fact.named,
        marked: fact.marked,
        cleared: fact.cleared,
        error: fact.error,
        observed_at: now()
      })
      |> Repo.insert!(on_conflict: :nothing)

    broadcast({:reconcile_observed, run.id})

    observation
  end

  @doc """
  The pass whose spaces are still unsettled — how far it got — or `nil`.

  This is a *cursor*, not a claim that anything is running: the pass may have
  been killed with no job left behind. Whether Oban still holds the job is
  `ConfluencePhxMirror.Jobs.unfinished?/1`, and a page that needs to say "a check
  is running" has to ask there. A pass older than the resume window is not
  returned: the next check starts a new one rather than continuing it.
  """
  @spec unfinished() :: %{run: t(), observed: non_neg_integer()} | nil
  def unfinished do
    case open() do
      nil -> nil
      run -> %{run: run, observed: MapSet.size(observed_space_ids(run))}
    end
  end

  @doc "Ids of the spaces this pass has settled, which is what a resumed attempt skips."
  @spec observed_space_ids(t()) :: MapSet.t(pos_integer())
  def observed_space_ids(%__MODULE__{} = run) do
    from(o in ReconcileObservation, where: o.run_id == ^run.id, select: o.space_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Every space this pass has settled so far, oldest observation first."
  @spec facts(t()) :: [ReconcileObservation.t()]
  def facts(%__MODULE__{} = run) do
    from(o in ReconcileObservation,
      where: o.run_id == ^run.id,
      order_by: [asc: o.observed_at, asc: o.id],
      preload: [:space]
    )
    |> Repo.all()
  end

  @doc """
  The newest facts of a pass, for a screen watching it work, with the total.

  Newest first, because the interesting row is the one that just arrived. The
  total is what the screen counts against, so a pass over a thousand spaces shows
  fifty rows and a number, not a thousand rows.
  """
  @spec progress_facts(t(), pos_integer()) :: %{
          facts: [ReconcileObservation.t()],
          settled: non_neg_integer()
        }
  def progress_facts(%__MODULE__{} = run, limit) do
    %{
      facts:
        from(o in ReconcileObservation,
          where: o.run_id == ^run.id,
          order_by: [desc: o.observed_at, desc: o.id],
          limit: ^limit,
          preload: [:space]
        )
        |> Repo.all(),
      settled: count_facts(run)
    }
  end

  @doc "How many spaces a pass has settled."
  @spec count_facts(t()) :: non_neg_integer()
  def count_facts(%__MODULE__{} = run) do
    Repo.aggregate(from(o in ReconcileObservation, where: o.run_id == ^run.id), :count)
  end

  @doc """
  What a pass compared and what it found, in numbers.

  The screen needs this to show its work: "found every page the site lists" is a
  conclusion, and a conclusion about a comparison nobody can see is
  indistinguishable from a pass that compared very little. `named` is the other
  half of that comparison — the ids the site answered with — and `counted` is how
  many spaces could be settled by a count instead of a full listing, which is
  zero on a Confluence that cannot report per-space totals.
  """
  @spec summary(t()) :: %{
          settled: non_neg_integer(),
          counted: non_neg_integer(),
          named: non_neg_integer(),
          marked: non_neg_integer(),
          cleared: non_neg_integer()
        }
  def summary(%__MODULE__{} = run) do
    rows =
      Repo.all(
        from(o in ReconcileObservation,
          where: o.run_id == ^run.id,
          select: {o.counted, o.named, o.marked, o.cleared}
        )
      )

    %{
      settled: length(rows),
      counted: Enum.count(rows, fn {counted, _named, _marked, _cleared} -> counted end),
      named: rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      marked: rows |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
      cleared: rows |> Enum.map(&elem(&1, 3)) |> Enum.sum()
    }
  end

  @doc """
  Records what the pass found.

  `listed` is a count of spaces rather than of pages: it is the number that
  explains the cost, since every other space was settled by two requests.
  """
  @spec finish(t(), map()) :: t()
  def finish(%__MODULE__{} = run, report) do
    finished =
      run
      |> Ecto.Changeset.change(%{
        finished_at: now(),
        spaces: report.spaces,
        agreed: report.agreed,
        listed: length(report.listed),
        absent: report.absent,
        asked: report.asked
      })
      |> Repo.update!()

    broadcast({:reconcile_finished, run.id})

    finished
  end

  @doc "The newest pass that finished, or `nil` when nobody has ever checked."
  @spec last_finished() :: t() | nil
  def last_finished do
    from(r in __MODULE__,
      where: not is_nil(r.finished_at),
      order_by: [desc: r.finished_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Every pass, newest first — the history behind a page that stays absent."
  @spec history(non_neg_integer()) :: [t()]
  def history(limit \\ 20) do
    from(r in __MODULE__, order_by: [desc: r.started_at], limit: ^limit)
    |> Repo.all()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(ConfluencePhxMirror.PubSub, @topic, message)
  end

  defp begun_since do
    DateTime.utc_now()
    |> DateTime.add(-@resume_window_seconds, :second)
    |> DateTime.truncate(:second)
  end
end
