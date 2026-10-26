defmodule ConfluencePhxMirror.Sync.ReconcileRun do
  @moduledoc """
  One verify pass: what it asked the site and what it found.

  `ConfluencePhxMirror.Sync.Reconcile` writes one of these per pass, because
  "nothing is absent" is only a fact *after* somebody asked. Without it the
  review screen cannot tell an untouched mirror from one the site agrees with,
  and it must not guess.

  `finished_at` is NULL while a pass runs and stays NULL if it never finished —
  a deploy or a kill. A half-finished pass has still marked absences, so the row
  is worth keeping; it just cannot be cited as "the last check".
  """

  use Ecto.Schema

  import Ecto.Query

  alias ConfluencePhxMirror.Repo

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
  Records what the pass found.

  `listed` is a count of spaces rather than of pages: it is the number that
  explains the cost, since every other space was settled by two requests.
  """
  @spec finish(t(), map()) :: t()
  def finish(%__MODULE__{} = run, report) do
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
end
