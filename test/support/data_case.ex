defmodule ConfluencePhxMirror.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ConfluencePhxMirror.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ConfluencePhxMirror.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ConfluencePhxMirror.DataCase

      use Oban.Testing, repo: ConfluencePhxMirror.Repo
    end
  end

  setup tags do
    ConfluencePhxMirror.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # SQLite allows one writer, and it does not wait for one: a transaction that
    # upgrades to a write while another connection holds the lock is answered
    # "Database busy" at once, whatever `busy_timeout` says. `--max-cases 1` is
    # not enough, because ExUnit runs a sync module while an async one is still
    # finishing — so the suite takes the lock itself, for the length of a test,
    # and only when it is pointed at SQLite. Postgres needs none of this.
    #
    # The lock is asked for by a process of its own rather than by the test:
    # `:global` frees a lock when the process that called `set_lock` dies, and a
    # test process dies *before* its `on_exit` callbacks run — so the next test
    # could take the lock while this one's transaction was still rolling back,
    # and its first write was answered "Database busy" (seen once on a CI
    # runner, where the two windows overlap). The holder outlives the test, and
    # the release is an `on_exit` registered *before* the sandbox owner's, which
    # makes it run after the rollback has finished.
    if Application.get_env(:confluence_phx_mirror, :sqlite_suite) do
      holder = hold_writer_lock()
      on_exit(fn -> release_writer_lock(holder) end)
    end

    # The cached totals are keyed on the newest write in the mirror, and a
    # rolled-back transaction puts the mirror back to an older version without
    # moving that key; every test starts from an empty cache instead.
    ConfluencePhxMirror.Mirror.Counters.clear()

    # The same for the theme an administrator chose: a test that stored one
    # would otherwise leave `:persistent_term` — which no rollback touches —
    # wearing it for whatever ran next.
    ConfluencePhxMirror.Settings.forget()

    # And for what the site said about itself, which every document's language
    # attribute is read from.
    ConfluencePhxMirror.SiteSettings.forget()

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(ConfluencePhxMirror.Repo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # The suite commits one copy of the demo site before the first test, so a
    # test that wants it pays a read. A test that wants a mirror holding only
    # what it built tags itself `:empty_mirror` and gets a blank one — emptied
    # inside its own transaction, so the shared copy survives. Such a file must
    # also be `async: false`: two of them empty the same committed rows and the
    # foreign keys deadlock.
    if tags[:empty_mirror] do
      ConfluencePhxMirror.Fixtures.empty_mirror!()
    end

    :ok
  end

  # The suite's one-writer lock, held by a process that outlives the test that
  # asked for it. See the call site in `setup_sandbox/1` for why it cannot be
  # the test process itself — and note that the *holder* is what asks: `:global`
  # frees a lock when the process that called `set_lock` dies, whichever process
  # the request was made in the name of (measured, not assumed).
  @doc "Takes the suite's one-writer lock out, and answers the process holding it."
  def hold_writer_lock do
    parent = self()

    holder =
      spawn(fn ->
        :global.set_lock({:sqlite_suite_writer, self()}, [node()], :infinity)
        send(parent, {:holding, self()})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:holding, ^holder} -> holder
    end
  end

  @doc "Gives the lock back, and answers once its holder is gone."
  def release_writer_lock(holder) do
    ref = Process.monitor(holder)
    send(holder, :stop)

    receive do
      {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
