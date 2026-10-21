defmodule ConfluencePhxMirror.Release do
  @moduledoc """
  Migration entry points for a release.

  Migrations live in two directories:

    * `priv/repo/migrations` — schema changes that old and new code can both
      live with. `migrate/0` applies them, and the container runs it on every
      boot before starting the server.
    * `priv/repo/manual_migrations` — slow, destructive or data migrations that
      need an operator's decision. Only `migrate_manual/0` applies them.

  Generating a manual migration and running it:

      mix ecto.gen.migration --migrations-path=priv/repo/manual_migrations backfill_status

      /app/bin/confluence_phx_mirror eval "ConfluencePhxMirror.Release.migrate_manual"

  In development and test both directories are applied together
  (`mix ecto.migrate_all`), so nobody has to remember the second one.
  """

  @app :confluence_phx_mirror
  @manual_migrations "manual_migrations"

  @doc """
  Applies the migrations that are safe to run automatically on deploy.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      path = Ecto.Migrator.migrations_path(repo)
      {:ok, _repo, _applied} = run_migrations(repo, path)
    end

    :ok
  end

  @doc """
  Applies the migrations that wait for a human: slow, destructive or data-only.
  """
  @spec migrate_manual() :: :ok
  def migrate_manual do
    load_app()

    for repo <- repos() do
      path = Ecto.Migrator.migrations_path(repo, @manual_migrations)
      {:ok, _repo, _applied} = run_migrations(repo, path)
    end

    :ok
  end

  defp run_migrations(repo, path) do
    Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, path, :up, all: true))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
