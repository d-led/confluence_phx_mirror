defmodule ConfluencePhxMirror.Repo.Migrations.AddNamedAndCountedToReconcileObservations do
  @moduledoc """
  What the site *named*, not only what was left out of it.

  `marked` records the pages a space's listing left out, which is what an operator
  acts on. It says nothing about what was compared: a pass that ends with "nothing
  absent" is indistinguishable from one that compared almost nothing, and the
  screen could only assert that everything was in step.

  `named` is how many ids the listing returned for the space — the other half of
  the comparison — and `counted` records whether the cheaper count was available
  at all. A Confluence that cannot report a per-space total (`:no_total`) leaves
  every space to be listed in full, and that is worth saying on the screen rather
  than leaving the operator to wonder why a check of 145 spaces cost 145 listings.
  """
  use Ecto.Migration

  def change do
    alter table(:reconcile_observations) do
      add :named, :integer, null: false, default: 0
      add :counted, :boolean, null: false, default: false
    end
  end
end
