defmodule ConfluencePhxMirror.DataCaseWriterSlotTest do
  @moduledoc """
  The suite's one-writer lock says no other *test* has asked for the database; it
  does not say the database is free. `stop_owner/1` answers before the connection
  it stopped has finished rolling back, so the previous test's transaction can
  still own SQLite's one write slot — and the next test's first write is answered
  "Database busy" (seen twice on CI runners, once inside a fixture's insert).

  So every SQLite test asks for the slot with a write of its own before it runs.
  This proves that ask is real: a second connection holding a write transaction
  is a writer, and the ask must not come back until that one is finished.
  """

  use ExUnit.Case, async: false

  @moduletag :sqlite_only

  alias ConfluencePhxMirror.DataCase
  alias ConfluencePhxMirror.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    owner = Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    # Not the sandbox: this connection holds the write lock on purpose, which is
    # the one thing the sandbox exists to avoid.
    {:ok, other} = Exqlite.Sqlite3.open(Repo.config()[:database])
    on_exit(fn -> Exqlite.Sqlite3.close(other) end)

    {:ok, other: other}
  end

  test "the ask waits for the connection that is writing", %{other: other} do
    :ok = Exqlite.Sqlite3.execute(other, "BEGIN IMMEDIATE")

    assert_raise RuntimeError, ~r/never came free/, fn -> DataCase.await_writer_slot!(1) end

    :ok = Exqlite.Sqlite3.execute(other, "COMMIT")

    assert DataCase.await_writer_slot!(1) == :ok
  end
end
