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

  require Logger

  # The oldest version in the shared migration set. A catalogue that does not
  # know it was built by the tool's own schema, which no longer exists.
  @first_shared 20_261_021_180_000

  @doc """
  Makes the catalogue on disk one this build can open.

  The tool's schema is the server's now. A catalogue written by an earlier build
  has the old tables and a `schema_migrations` that knows nothing of the shared
  migrations, so applying them starts at the first one and collides with what is
  already there — a boot that dies on `table "spaces" already exists`, and a
  window with nothing to click.

  Such a file is *renamed*, not deleted: the pages in it are somebody's work and
  it is still a readable SQLite database. Rebuilding from Confluence is a mirror
  away, and losing the file without being asked would not be.

  Called before the repo starts, because the file cannot be renamed underneath
  an open connection.
  """
  @spec prepare(Path.t()) :: :ok
  def prepare(database) do
    if incompatible?(database), do: set_aside(database)
    :ok
  end

  @doc "Applies anything pending. Safe to call on every start."
  @spec migrate() :: :ok
  def migrate do
    Ecto.Migrator.run(Repo, migrations_dir(), :up, all: true, log: false)
    :ok
  end

  @doc """
  Applies the migrations, then declines to be supervised.

  A child placed straight after the repo: a supervisor starts its children in the
  order they are listed, and this does its work in `start_link`, so nothing that
  queries the catalogue can start against a schema from last week — or, on a
  fresh install, against no schema at all. `:ignore` says there is nothing to keep
  running once the work is done.
  """
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :temporary}
  end

  @spec start_link() :: :ignore
  def start_link do
    migrate()
    :ignore
  end

  # A file with applied migrations that do not include the first shared one came
  # from an earlier build. A file with none at all is either new or empty, and the
  # migrator knows what to do with both.
  defp incompatible?(database) do
    case applied_versions(database) do
      [] -> false
      versions -> @first_shared not in versions
    end
  end

  defp set_aside(database) do
    target = "#{database}.before-shared-schema-#{System.system_time(:second)}"

    for suffix <- ["", "-wal", "-shm"], File.exists?(database <> suffix) do
      File.rename!(database <> suffix, target <> suffix)
    end

    Logger.warning(
      "the catalogue at #{database} was built by an earlier version and cannot be " <>
        "migrated; it is kept at #{target}, and a new one is being created"
    )
  end

  defp applied_versions(database) do
    with true <- File.exists?(database),
         {:ok, conn} <- Exqlite.Sqlite3.open(database) do
      try do
        query(conn, "select version from schema_migrations") |> Enum.map(&hd/1)
      after
        Exqlite.Sqlite3.close(conn)
      end
    else
      _absent_or_unreadable -> []
    end
  rescue
    # No `schema_migrations` table: a new file, or one that was never ours.
    _no_table -> []
  end

  defp query(conn, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      collect(conn, statement, [])
    after
      Exqlite.Sqlite3.release(conn, statement)
    end
  end

  defp collect(conn, statement, acc) do
    case Exqlite.Sqlite3.step(conn, statement) do
      {:row, row} -> collect(conn, statement, [row | acc])
      :done -> Enum.reverse(acc)
      {:error, reason} -> raise reason
    end
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
