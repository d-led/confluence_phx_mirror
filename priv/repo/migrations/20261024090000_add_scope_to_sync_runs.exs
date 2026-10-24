defmodule ConfluencePhxMirror.Repo.Migrations.AddScopeToSyncRuns do
  @moduledoc """
  What a run covered: the whole site, one space or one page.

  `mode` says how a run was asked for (a snapshot, an incremental pull, a
  webhook), which does not tell a space pull from a site pull — both are
  incremental — so the dashboard could not say which space a run had touched.
  """
  use Ecto.Migration

  def change do
    alter table(:sync_runs) do
      add :scope, :string
    end
  end
end
