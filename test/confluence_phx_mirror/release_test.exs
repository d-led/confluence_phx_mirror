defmodule ConfluencePhxMirror.ReleaseTest do
  # Not async: the migrator needs the sandbox pool in shared mode.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Release
  alias ConfluencePhxMirror.Repo

  test "manual migrations have their own directory inside the release" do
    path = Ecto.Migrator.migrations_path(Repo, "manual_migrations")

    assert Path.basename(path) == "manual_migrations"
    assert File.dir?(path)
  end

  test "applies the manual migrations on demand" do
    # The migrator runs DDL outside the per-test sandbox transaction, so it
    # needs the owner's connection.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    assert Release.migrate_manual() == :ok
  end
end
