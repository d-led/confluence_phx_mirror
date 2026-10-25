defmodule ConfluencePhxMirror.Resources do
  @moduledoc """
  What the mirror costs to keep: the mount its attachments live on, the room
  left on that device, and the database behind it.

  The mount is answered from the last measurement rather than measured on the
  spot. An admin screen re-reads its numbers every five seconds, and a mirror
  can hold a hundred thousand attachment files: walking that tree on every tick
  would cost more than every query on the page together. One process walks it
  once a minute and remembers the answer (`refresh/0` measures immediately).

  The database is asked every time — `pg_database_size/1` is a catalogue lookup,
  and while a sync runs those are the numbers an operator watches move.
  """

  use GenServer

  alias ConfluencePhxMirror.Blobs.LocalStore

  @measure_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The blob mount as last measured, with the device it lives on.

  Returns `%{path:, used_bytes:, files:, device:, measured_at:}`, where
  `device` is `%{filesystem:, mount:, total_bytes:, used_bytes:, free_bytes:,
  percent:}` or `nil` when the operating system would not say.
  """
  def mount, do: GenServer.call(__MODULE__, :mount)

  @doc "Measure the mount again now, and answer with the new numbers."
  def refresh, do: GenServer.call(__MODULE__, :refresh, :infinity)

  @doc """
  Measure one mount. `root` defaults to the configured blob store.

  Public because it is what `refresh/0` runs: a test can point it at a
  directory it made, instead of at the store the suite is writing to.
  """
  def measure(root \\ nil) do
    path = root || LocalStore.root([])
    {bytes, files} = walk(path)

    %{
      path: path,
      used_bytes: bytes,
      files: files,
      device: device(path),
      measured_at: DateTime.utc_now()
    }
  end

  @doc """
  The running database, in bytes, and its biggest tables.

  `bytes` is the database; `tablespace_bytes` is everything the default
  tablespace holds, WAL included — the figure that grows when a sync writes hard
  and the one that fills a volume. Postgres has no function that answers "how
  much is left": there is no `statvfs` behind SQL, so free space can only be
  computed against a device size the deployment knows
  (`CM_DATABASE_CAPACITY_GB`, see `database_capacity/0`).
  """
  def database do
    %{rows: [[bytes, tablespace_bytes]]} =
      Ecto.Adapters.SQL.query!(
        ConfluencePhxMirror.Repo,
        "select pg_database_size(current_database()), pg_tablespace_size('pg_default')",
        []
      )

    # `pg_total_relation_size` per user table: a couple of catalogue lookups on
    # a schema of a few dozen tables, which is why this can be asked per tick.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        ConfluencePhxMirror.Repo,
        "select relname, pg_total_relation_size(relid)::bigint " <>
          "from pg_stat_user_tables order by 2 desc limit 3",
        []
      )

    %{
      bytes: bytes,
      tablespace_bytes: tablespace_bytes,
      tables: Enum.map(rows, fn [name, size] -> {name, size} end)
    }
  end

  @doc "How big the database's device is, when the deployment says so."
  def database_capacity, do: Application.get_env(:confluence_phx_mirror, :database_capacity_bytes)

  @doc """
  The machine's memory, and how much of it this VM holds.

  `used_bytes` counts what cannot be handed out — the total minus the memory
  that is *available*, not the memory that is free: a healthy Linux box keeps
  most of its RAM in the page cache, and calling that "99% used" would be an
  alarm nobody should act on. `beam_bytes` is this node's own heap, which is
  the half of the answer a sync can blow up.

  `nil` when the operating system has not reported yet (memsup samples on its
  own schedule), which is a reason to draw nothing rather than a zero.
  """
  def memory do
    data = :memsup.get_system_memory_data()
    total = Keyword.get(data, :system_total_memory) || Keyword.get(data, :total_memory)
    available = Keyword.get(data, :available_memory) || Keyword.get(data, :free_memory)

    if is_integer(total) and total > 0 and is_integer(available) do
      %{
        total_bytes: total,
        available_bytes: available,
        used_bytes: total - available,
        percent: round((total - available) * 100 / total),
        beam_bytes: :erlang.memory(:total)
      }
    end
  end

  # Everything under the root, one entry at a time. `lstat` and not `stat`: a
  # symlink is not a file the store wrote, and following one could walk out of
  # the tree or round in a circle.
  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, {0, 0}, fn entry, acc ->
          combine(acc, measure_entry(Path.join(dir, entry)))
        end)

      {:error, _missing} ->
        # A store nobody has written to yet holds nothing; that is not an error.
        {0, 0}
    end
  end

  defp measure_entry(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path)
      {:ok, %File.Stat{type: :regular, size: size}} -> {size, 1}
      _other -> {0, 0}
    end
  end

  defp combine({bytes, files}, {more_bytes, more_files}),
    do: {bytes + more_bytes, files + more_files}

  # The device the mount sits on, as the operating system reports it: total,
  # used and free for that filesystem — not the mirror's share of it. `df -P`
  # is the portable spelling (POSIX output, one line, path in, filesystem out).
  defp device(path) do
    with target when is_binary(target) <- existing(path),
         {out, 0} <- System.cmd("df", ["-kP", target], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [filesystem, total, used, free, capacity | mount] <- String.split(line) do
      %{
        filesystem: filesystem,
        mount: Enum.join(mount, " "),
        total_bytes: blocks(total),
        used_bytes: blocks(used),
        free_bytes: blocks(free),
        percent: capacity |> String.trim_trailing("%") |> String.to_integer()
      }
    else
      _unknown -> nil
    end
  end

  # `df` wants a path that exists; before the first attachment the store's own
  # directory may not — the disk is still there, one level up.
  defp existing(path) do
    cond do
      File.exists?(path) -> path
      Path.dirname(path) == path -> path
      true -> existing(Path.dirname(path))
    end
  end

  defp blocks(kilobytes), do: String.to_integer(kilobytes) * 1024

  @impl true
  def init(_opts) do
    :timer.send_interval(@measure_ms, self(), :measure)
    {:ok, measure()}
  end

  @impl true
  def handle_call(:mount, _from, measured), do: {:reply, measured, measured}

  def handle_call(:refresh, _from, _measured) do
    fresh = measure()
    {:reply, fresh, fresh}
  end

  @impl true
  def handle_info(:measure, _measured), do: {:noreply, measure()}
end
