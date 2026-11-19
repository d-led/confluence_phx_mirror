defmodule ConfluencePhxMirror.Sync.WorkOwnerTest do
  @moduledoc """
  A run's work belongs to the process that asked for it.

  Unlinked, a sync outlives its job: cancelling the job in Oban killed the row
  and left the reading going, so the mirror kept a `running` run with no job
  behind it and page jobs queued behind a run nobody could see. These tests pin
  the property the queue depends on — when the caller dies, the work dies with
  it — and the two ways a person or a job gets out of a run's way.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.Runs

  # A source that never finishes on its own: the run is still working when the
  # caller is killed, which is exactly the window the leak lives in.
  defmodule Blocking do
    @moduledoc false
    def name, do: "a source that never answers"

    def page(_confluence_id, _opts) do
      Process.sleep(30_000)
      {:error, :never}
    end
  end

  # `Sync.run/2` is given a gate by a test that owns the mirror outright; the
  # work's lifetime has nothing to do with the lock.
  defmodule FreeGate do
    @moduledoc false
    def exclusive(fun), do: {:ok, fun.(Ecto.UUID.generate())}
  end

  test "the work of a run dies with the process that asked for it" do
    parent = self()

    caller =
      spawn(fn ->
        # The sandbox is checked out by the test process; a caller of its own has
        # to say whose work it is, exactly as `Sync` does for the child it spawns.
        Process.put(:"$callers", [parent | Process.get(:"$callers", [])])

        try do
          result = Sync.run(:page, confluence_id: 1002, source: Blocking, gate: FreeGate)
          send(parent, {:caller_finished, result})
        rescue
          error -> send(parent, {:caller_finished, {:raised, Exception.message(error)}})
        catch
          kind, reason -> send(parent, {:caller_finished, {:caught, kind, reason}})
        end
      end)

    receive do
      {:caller_finished, result} -> flunk("the run ended instead of working: #{inspect(result)}")
    after
      500 -> :ok
    end

    wait_until(fn -> Runs.running() != [] end)
    Process.exit(caller, :kill)

    wait_until(fn -> Runs.running() == [] end)
    refute Runs.running() != []
  end

  defp wait_until(condition, attempts \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("the condition never became true")

      true ->
        Process.sleep(20)
        wait_until(condition, attempts - 1)
    end
  end
end
