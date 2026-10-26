defmodule ConfluencePhxMirror.Repo.Migrations.CreateReconcileObservations do
  @moduledoc """
  One row per space per pass: what the pass learned about that space, and when.

  A pass over a site of a thousand spaces is a long job, and a long job meets
  deploys. Without these rows an interruption threw away everything the pass had
  learned and the next attempt started at the first space again; with them a pass
  is a sequence of small, recorded facts, and a second attempt continues after
  the last one.

  A row exists only once its space is *done* — counted, listed, marked — so the
  rows are also the pass's cursor. Marking is idempotent (`Mirror.mark_absent/2`
  sets and clears by set membership), which is what makes it safe to record after
  acting rather than before.
  """
  use Ecto.Migration

  def change do
    create table(:reconcile_observations) do
      add :run_id, references(:reconcile_runs, on_delete: :delete_all), null: false
      add :space_id, references(:spaces, on_delete: :delete_all), null: false

      # "agreed" (the counts matched), "listed" (the pages were named),
      # "empty" (the site named nothing, which marks nothing) or "failed".
      add :verdict, :string, null: false
      # Questions put to the source for this space: one count, plus one listing
      # when the count disagreed or could not be asked.
      add :asked, :integer, null: false, default: 0
      add :marked, :integer, null: false, default: 0
      add :cleared, :integer, null: false, default: 0
      add :error, :string
      add :observed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One verdict per space per pass, which is what lets a retry re-record a
    # space without duplicating it.
    create unique_index(:reconcile_observations, [:run_id, :space_id])

    # The pass asks "which spaces have I already done?".
    create index(:reconcile_observations, [:run_id])
  end
end
