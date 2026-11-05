defmodule ConfluencePhxMirror.Migration do
  @moduledoc """
  What the two storages spell differently, in one place.

  There is one set of migrations, because the migrations are the schema and two
  copies of it would drift. The constructs below are the ones with no SQLite
  equivalent; writing them here rather than at each call site means a migration
  says `add :labels, Migration.list_type(:string)` and produces `text[]` on the
  server and JSON text in the tool, from the same line.

  Which storage it is, is the adapter this environment compiled with — see
  `ConfluencePhxMirror.Repo`. Nothing here runs at boot.
  """

  import Ecto.Migration

  @doc """
  Whether this build talks to Postgres.

  Read from the same key that chose the adapter — the one `ConfluencePhxMirror.Repo`
  compiled with. Reading it rather than compiling it in is what keeps the answer
  out of the compiler's constant folding, which warns about a branch it can prove.
  """
  @spec postgres?() :: boolean()
  def postgres? do
    Application.get_env(:confluence_phx_mirror, :repo_adapter, Ecto.Adapters.Postgres) ==
      Ecto.Adapters.Postgres
  end

  @doc """
  The type of a list column.

  `text[]` where the database has an array type; `text` holding JSON where it
  does not. `ConfluencePhxMirror.Schema`'s list type is chosen by the same rule,
  so a value written here reads back as a list either way.
  """
  @spec list_type(atom()) :: atom() | {:array, atom()}
  def list_type(type) do
    if postgres?(), do: {:array, type}, else: :text
  end

  @doc """
  The options for a list column, whose empty default is spelled differently.

  Postgres writes `DEFAULT '{}'`; JSON text writes `DEFAULT '[]'`. Both mean the
  same empty list to the code that reads them.
  """
  @spec list_options(keyword()) :: keyword()
  def list_options(opts \\ []) do
    if postgres?(), do: Keyword.put(opts, :default, []), else: Keyword.put(opts, :default, "[]")
  end

  @doc """
  An index a containment or full-text query can be answered from.

  Postgres answers these from GIN; SQLite has no access methods at all, so the
  ordinary index is created and its full-text work is done by an FTS5 table of
  its own (`ConfluencePhxMirror.Mirror.Search` says which).
  """
  def search_index(table, columns) do
    if postgres?() do
      create index(table, columns, using: :gin)
    else
      create index(table, columns)
    end
  end

  @doc "An extension, where the database has them."
  @spec extension(String.t()) :: :ok | nil
  def extension(name) do
    if postgres?(), do: execute("CREATE EXTENSION IF NOT EXISTS #{name}")
  end

  @doc """
  An index, built the way this database can build it.

  Postgres builds it `CONCURRENTLY` — so a deploy does not stop the writers — and
  can restrict it to a subset of rows with `where:`. SQLite has neither option
  and no second writer to block, so both are dropped and the plain index is
  built.
  """
  def create_index(table, columns, opts \\ []) do
    opts = if postgres?(), do: opts, else: Keyword.drop(opts, [:concurrently, :where])
    create(index(table, columns, opts))
  end

  @doc """
  An index built without stopping the release that is serving.

  Postgres builds it `CONCURRENTLY`, outside a transaction. SQLite has no such
  option — and no second writer to block — so it builds the ordinary index under
  the same name.
  """
  @spec build_index(String.t(), atom(), [atom()]) :: :ok | nil
  def build_index(name, table, columns) do
    if postgres?() do
      execute(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} " <>
          "ON #{table} (#{Enum.join(columns, ", ")})",
        "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
      )
    else
      create index(table, columns, name: name)
    end
  end
end
