defmodule ConfluencePhxMirror.Export.Artifact do
  @moduledoc """
  A finished archive on disk, and the one build that makes it.

  A whole site is hundreds of megabytes and takes minutes to produce, and a
  response that *generates* what it sends cannot be resumed: the second attempt
  is not the bytes of the first, and there is no length to name. So, when a
  deployment asks for it (`export.prepared`, seeded by `CM_EXPORT_PREPARED`),
  the archive is written to a file before anyone downloads it, and every
  download from then on is a file send — with a length, and with ranges, which
  is what a browser's "resume" needs. A deployment that leaves it off streams
  the archive as it is generated, exactly as before.

  One build at a time, whoever asks first: a hundred thousand pages is the one
  thing this mirror does that costs more than a request, and two of them on one
  small machine is how the machine dies. Who started the build, how many bytes
  it has written and how it ended are all here, so the screen that offers the
  button can say "being prepared by somebody else, 132 MB so far" rather than
  starting a second one.

  The file lives under the deployment's temporary folder — `CM_EXPORT_TMP_DIR`,
  the OS temporary directory by default, which on a Fly machine is the disk the
  machine owns. It is a cache: a build that a deploy interrupts is not resumed,
  the next ask starts again, and the folder is emptied at boot.
  """

  use GenServer

  require Logger

  @subdir "confluence-mirror-exports"

  # How long a finished archive is offered before the next ask builds a new one.
  # It is a snapshot of the mirror, and the mirror moves; the download's own
  # name carries the moment it was built.
  @keep_ms 10 * 60 * 1000
  @sweep_ms 2 * 60 * 1000

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The folder artifacts are written to, created on demand.

  `CM_EXPORT_TMP_DIR` when the deployment sets it, the OS temporary directory
  otherwise; the archives live in a directory of their own inside it, so that
  emptying it at boot cannot touch anything else there.
  """
  @spec dir() :: Path.t()
  def dir do
    root =
      :confluence_phx_mirror
      |> Application.get_env(:export_tmp_dir)
      |> Kernel.||(System.tmp_dir!())

    Path.join(root, @subdir)
  end

  @doc "Where the archive called `name` is written."
  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(dir(), name)

  @doc """
  Starts building `name` unless it is ready, being built, or impossible.

  `:build` is called in a process of its own with an `emit` function; every
  binary it emits is appended to the file, so the archive is written as it is
  generated and never held in memory.

      Artifact.prepare("site.zip", by: "ops@example.com", build: fn emit ->
        entries
        |> ConfluencePhxMirror.Export.Zip.chunks()
        |> Enum.each(fn chunk -> emit.(IO.iodata_to_binary(chunk)) end)
      end)
  """
  @spec prepare(String.t(), keyword()) :: :started | :ready | {:busy, String.t() | nil}
  def prepare(name, opts) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:prepare, name, opts}, :infinity)
  end

  @doc """
  What is happening to `name`.

    * `:absent` — nothing was built, or the last build failed;
    * `{:building, %{by: who, since: datetime, bytes: n}}` — one build is running,
      and `n` is how much of the archive is already on disk;
    * `{:ready, %{bytes: n, at: datetime, by: who}}` — a file to download.
  """
  @spec status(String.t(), GenServer.server()) ::
          :absent
          | {:building, %{by: String.t() | nil, since: DateTime.t(), bytes: non_neg_integer()}}
          | {:ready, %{bytes: non_neg_integer(), at: DateTime.t(), by: String.t() | nil}}
  def status(name, server \\ __MODULE__) do
    case :ets.lookup(server, name) do
      [{^name, status}] -> status
      [] -> :absent
    end
  end

  @doc "Deletes every artifact, ready or half-written."
  @spec forget(GenServer.server()) :: :ok
  def forget(server \\ __MODULE__) do
    GenServer.call(server, :forget)
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def init(opts) do
    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      dir: Path.join(Keyword.get(opts, :dir, dir_root(opts)), @subdir),
      keep_ms: Keyword.get(opts, :keep_ms, @keep_ms),
      sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms)
    }

    :ets.new(state.name, [:named_table, :public, :set, read_concurrency: true])
    # A build does not survive a restart, so neither does a file: a half-written
    # archive on disk would answer a download with a zip that stops halfway.
    File.rm_rf(state.dir)
    File.mkdir_p!(state.dir)
    :timer.send_interval(state.sweep_ms, :sweep)

    {:ok, state}
  end

  # The folder the artifacts go *in*, before the subdirectory of their own.
  defp dir_root(opts) do
    Keyword.get_lazy(opts, :dir, fn ->
      :confluence_phx_mirror
      |> Application.get_env(:export_tmp_dir)
      |> Kernel.||(System.tmp_dir!())
    end)
  end

  @impl true
  def handle_call({:prepare, name, opts}, _from, state) do
    case status(name, state.name) do
      {:ready, %{at: at}} ->
        {:reply, if(fresh?(at, state), do: :ready, else: start(state, name, opts)), state}

      {:building, %{by: by}} ->
        {:reply, {:busy, by}, state}

      :absent ->
        {:reply, start(state, name, opts), state}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def handle_call(:forget, _from, state) do
    File.rm_rf(state.dir)
    File.mkdir_p!(state.dir)
    :ets.delete_all_objects(state.name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:built, name, bytes, by}, state) do
    :ets.insert(state.name, {name, {:ready, %{bytes: bytes, at: DateTime.utc_now(), by: by}}})
    {:noreply, state}
  end

  # The file name is this module's own (see `path/1`): a fixed name inside a
  # folder the deployment configured, never anything a request carried.
  # sobelow_skip ["Traversal.FileModule"]
  def handle_info({:failed, name, error}, state) do
    :ets.insert(state.name, {name, :absent})
    File.rm(Path.join(state.dir, name))
    Logger.warning("the export #{name} failed: #{Exception.message(error)}")
    {:noreply, state}
  end

  # sobelow_skip ["Traversal.FileModule"]
  def handle_info(:sweep, state) do
    Enum.each(:ets.tab2list(state.name), fn {name, status} ->
      if stale?(status, state) do
        :ets.delete(state.name, name)
        File.rm(Path.join(state.dir, name))
      end
    end)

    {:noreply, state}
  end

  defp start(state, name, opts) do
    by = Keyword.get(opts, :by)
    build = Keyword.fetch!(opts, :build)
    file = Path.join(state.dir, name)
    since = DateTime.utc_now()

    progress(state.name, name, %{by: by, since: since, bytes: 0})

    parent = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(ConfluencePhxMirror.Export.TaskSupervisor, fn ->
        try do
          write(state.name, name, %{by: by, since: since, bytes: 0}, file, build)
          send(parent, {:built, name, File.stat!(file).size, by})
        rescue
          error -> send(parent, {:failed, name, error})
        end
      end)

    :started
  end

  # The file is opened before the first entry exists and closed after the last,
  # so nothing but one batch of the zip is ever in memory — which is what lets a
  # mirror of a hundred thousand pages be written by a small machine. The same
  # `emit` keeps the screen's count honest: the bytes on disk are the progress.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(server, name, build_of, file, build) do
    File.open!(file, [:write, :raw, :binary], fn device ->
      build.(fn chunk ->
        :ok = IO.binwrite(device, chunk)
        progress(server, name, %{build_of | bytes: position(device)})
      end)
    end)
  end

  defp progress(server, name, building), do: :ets.insert(server, {name, {:building, building}})

  defp position(device) do
    {:ok, position} = :file.position(device, :cur)
    position
  end

  defp fresh?(at, state), do: DateTime.diff(DateTime.utc_now(), at, :millisecond) < state.keep_ms

  defp stale?({:building, %{since: since}}, state), do: not fresh?(since, state)
  defp stale?({:ready, %{at: at}}, state), do: not fresh?(at, state)
  defp stale?(_other, _state), do: false
end
