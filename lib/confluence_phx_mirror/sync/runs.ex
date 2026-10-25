defmodule ConfluencePhxMirror.Sync.Runs do
  @moduledoc """
  The sync work running on this node, by run id.

  A cancel is a process exit, not a flag the next page happens to notice. The
  work of a run happens in a child of the process that owns the run row (see
  `ConfluencePhxMirror.Sync.run/2`), so stopping it is exiting that child: the
  page it was writing is one transaction and rolls back, and the parent records
  the run as cancelled and releases the gate.

  This registry is how a request that arrives in another process — the admin
  dashboard — finds that child. A run started by another node, or by
  `mix confluence.sync` in its own OS process, has no pid here; for those the
  row's `cancel_requested_at` stays the signal, and the loops read it between
  pages.
  """

  @registry __MODULE__

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc "Records the calling process as the one doing `run_id` on this node."
  @spec register(integer()) :: :ok
  def register(run_id) do
    # The sync gate admits one run at a time, so a second registration is a
    # leftover entry, not a second run: the newest process is the truth.
    case Registry.register(@registry, run_id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @doc "The run ids this node is doing right now."
  @spec running() :: [integer()]
  def running do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Stops the local process doing `run_id`.

  `:stopped` when this node was running it; `:elsewhere` when the run belongs
  to another node or OS process, where only the row can carry the request.
  """
  @spec stop(integer()) :: :stopped | :elsewhere
  def stop(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] ->
        Process.exit(pid, :shutdown)
        :stopped

      [] ->
        :elsewhere
    end
  end
end
