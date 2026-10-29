defmodule ConfluencePhxMirror.Repo.Migrations.MoveTriggerOutOfStats do
  use Ecto.Migration

  # The other half of `20261029172000_add_trigger_to_sync_runs`: the trigger
  # used to be one key of a run's `stats`, and the column now holds it.
  # `SyncRun.trigger/1` reads both, so this is a tidy-up rather than a repair:
  # run it when the dashboard's older rows should stop carrying the answer in a
  # JSON blob as well as in its column.
  #
  # Idempotent: a row already moved has no `trigger` key left to move.
  def up do
    execute(
      "UPDATE sync_runs SET trigger = stats->>'trigger' " <>
        "WHERE trigger IS NULL AND stats ? 'trigger'"
    )

    execute("UPDATE sync_runs SET stats = stats - 'trigger' WHERE stats ? 'trigger'")
  end

  def down do
    execute(
      "UPDATE sync_runs SET stats = jsonb_set(stats, '{trigger}', to_jsonb(trigger)) " <>
        "WHERE trigger IS NOT NULL AND NOT stats ? 'trigger'"
    )

    execute("UPDATE sync_runs SET trigger = NULL")
  end
end
