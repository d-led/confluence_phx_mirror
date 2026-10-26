defmodule ConfluencePhxMirror.Sync.ReconcileObservation do
  @moduledoc """
  One space, one pass, one verdict — the fact a pass is made of.

  Rows exist so a pass survives being interrupted: an attempt records the space
  it has finished and the next attempt starts after the last recorded row. They
  are written *after* the space has been counted, listed and marked, so a row is
  a promise that its work is done. A pass killed between the marking and the
  recording re-does one space, which is idempotent; never the other way round.

  `observed_at` is per row rather than per pass on purpose. A pass that spans a
  deploy can be hours old at its first row and seconds old at its last, and a
  fact is only worth what its age is worth.
  """

  use Ecto.Schema

  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Sync.ReconcileRun

  @type verdict :: :agreed | :listed | :empty | :failed

  @type t :: %__MODULE__{}

  schema "reconcile_observations" do
    field :verdict, :string
    field :asked, :integer
    field :marked, :integer
    field :cleared, :integer
    # The other half of the comparison: how many ids the listing named, and
    # whether the cheaper count was available for this space at all.
    field :named, :integer
    field :counted, :boolean
    field :error, :string
    field :observed_at, :utc_datetime

    belongs_to :run, ReconcileRun
    belongs_to :space, Space

    timestamps(type: :utc_datetime)
  end
end
