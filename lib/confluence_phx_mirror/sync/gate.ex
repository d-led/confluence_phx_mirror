defmodule ConfluencePhxMirror.Sync.Gate do
  @moduledoc """
  One run at a time — across triggers, and across nodes.

  A snapshot, the hourly schedule, a webhook, a space refresh and `mix
  confluence.sync` all end up in `Sync.run/2`, and two of them copying the same
  pages is wasted work at best and a half-written page at worst. Oban's uniques
  cover one queue and one node; this covers the mirror.

  The claim is a row (`sync_gate`) taken by whoever starts a run, and it holds a
  *lease* rather than a lock. A lease because a Postgres session lock belongs to
  a connection, and a mirror is not one connection: it has a pool, two Machines,
  and deploys that kill what they cannot see. A lease says "this run was alive at
  this moment"; whoever holds the row renews it as it works, and a run whose
  lease lapsed is by definition no longer alive. That is what makes an abandoned
  run recognisable (`Sync.abandon_abandoned_runs/0`) instead of leaving a
  `running` row nobody can explain.

  Every statement is short and atomic, so a claim needs no transaction and no
  second connection.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Repo

  # A lease short enough that a crashed node or a killed deploy frees the gate
  # within a minute and a half — which is also how long an abandoned run can
  # look alive. It is renewed by a heartbeat that runs for exactly as long as
  # the claiming process does, so a healthy run never gets near the end of it,
  # and a run never has to remember to say it is alive (the details pass is
  # three requests per page and flushes no progress at all).
  @lease_seconds 90
  @heartbeats_per_lease 3

  @typedoc "The caller's own result, or the news that someone else holds the gate."
  @type result(result) :: {:ok, result} | {:error, :already_running}

  @doc """
  Runs `fun` while holding the gate, or answers `{:error, :already_running}`.

  `fun` receives its owner token, which is what `renew/1` uses: the token is the
  claim, and a renew with someone else's token changes nothing.
  """
  @spec exclusive((owner :: String.t() -> result)) :: result(result) when result: term()
  def exclusive(fun) do
    owner = Ecto.UUID.generate()

    if claim(owner) do
      heartbeat = keep_alive(owner)

      try do
        {:ok, fun.(owner)}
      after
        stop_sharing(heartbeat)
        release(owner)
      end
    else
      {:error, :already_running}
    end
  end

  # The claim renews itself for as long as the process that made it is alive,
  # and stops when that process exits. A lease that depends on the workload
  # remembering to renew it is a lease that lapses in the middle of the one
  # phase nobody thought about; this one cannot be forgotten.
  defp keep_alive(owner) do
    claimant = self()

    Task.start(fn ->
      ref = Process.monitor(claimant)
      beat(owner, ref)
    end)
  end

  defp beat(owner, ref) do
    receive do
      :stop -> :ok
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      heartbeat_ms() ->
        renew(owner)
        beat(owner, ref)
    end
  end

  defp stop_sharing({:ok, pid}) do
    send(pid, :stop)
    :ok
  end

  @doc "Whether the gate is currently claimed by a run that is still alive."
  @spec held?() :: boolean()
  def held? do
    now = now()

    Repo.exists?(
      from(g in "sync_gate",
        where: g.id and not is_nil(g.expires_at) and g.expires_at > ^now
      )
    )
  end

  @doc """
  Pushes the lease forward for the run that owns the gate.

  Called by the heartbeat `exclusive/1` starts, on every progress flush would
  also be fine but is not needed: a claim is only worth anything if it keeps
  saying "alive", and this makes it say so without the workload's help.
  """
  @spec renew(String.t() | nil) :: :ok
  def renew(nil), do: :ok

  def renew(owner) do
    from(g in "sync_gate", where: g.owner == ^owner)
    |> Repo.update_all(set: [expires_at: expires_at()])

    :ok
  end

  # One statement decides it: the insert wins on a free or lapsed row, and does
  # nothing while a live lease is held by someone else.
  defp claim(owner) do
    %{num_rows: rows} =
      Repo.query!(
        """
        INSERT INTO sync_gate (id, owner, expires_at) VALUES (true, $1, $2)
        ON CONFLICT (id) DO UPDATE SET owner = $1, expires_at = $2
        WHERE sync_gate.expires_at IS NULL OR sync_gate.expires_at < $3
        RETURNING id
        """,
        [owner, expires_at(), now()]
      )

    rows == 1
  end

  defp release(owner) do
    from(g in "sync_gate", where: g.owner == ^owner)
    |> Repo.update_all(set: [owner: nil, expires_at: nil])
  end

  defp expires_at, do: DateTime.add(now(), lease_seconds(), :second)

  defp heartbeat_ms, do: div(lease_seconds() * 1000, @heartbeats_per_lease)

  defp lease_seconds do
    :confluence_phx_mirror
    |> Application.get_env(:sync, [])
    |> Keyword.get(:gate_lease_seconds, @lease_seconds)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
