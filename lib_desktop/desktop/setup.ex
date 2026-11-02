defmodule ConfluencePhxMirror.Desktop.Setup do
  @moduledoc """
  Brings the catalogue file up to date when the tool starts.

  There is no deploy step to hang a migration task on: a person double-clicks the
  app. So the migration runs at boot, from `priv/repo/migrations` — the server's
  own migrations, which build the same schema on SQLite that they build on
  Postgres. Running it every start is cheap — Ecto records what it has applied —
  and it means an upgrade is opening the app again.
  """

  alias ConfluencePhxMirror.Repo

  @doc "Applies anything pending. Safe to call on every start."
  @spec migrate() :: :ok
  def migrate do
    Ecto.Migrator.run(Repo, migrations_dir(), :up, all: true, log: false)
    :ok
  end

  # One set of migrations, not a second copy for the tool: the schema is the same
  # schema, and two definitions of it would drift.
  defp migrations_dir do
    Path.join(priv_dir(), "repo/migrations")
  end

  defp priv_dir do
    :confluence_phx_mirror |> :code.priv_dir() |> to_string()
  end
end
