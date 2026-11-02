defmodule ConfluencePhxMirror.Desktop.Jobs do
  @moduledoc """
  The one mirror run the tool can have going at a time.

  A single user with a single catalogue has no reason to run two mirrors
  concurrently, and every reason not to: they would write the same rows and
  compete for the same rate limit. So this holds one job, refuses a second, and
  answers the screen's question — what is happening, and how far along.

  The work itself runs under the task supervisor rather than in this process, so
  a slow space never blocks the web server that is showing its progress.
  """

  use GenServer

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Desktop.Mirror

  @type state :: :idle | :running | :done | :error
  @type status :: %{
          state: state(),
          space_key: String.t() | nil,
          done: non_neg_integer(),
          total: non_neg_integer(),
          error: term()
        }

  @idle %{state: :idle, space_key: nil, done: 0, total: 0, error: nil}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "What the mirror is doing, for the screen that refreshes."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Starts mirroring `space_key`, or says a run is already going.
  """
  @spec start_mirror(String.t(), keyword()) :: {:ok, :started} | {:error, :busy}
  def start_mirror(space_key, opts \\ []) do
    GenServer.call(__MODULE__, {:start_mirror, space_key, Keyword.get(opts, :source)})
  end

  @doc false
  def progress(done, total), do: GenServer.cast(__MODULE__, {:progress, done, total})

  @doc false
  def finished(result), do: GenServer.cast(__MODULE__, {:finished, result})

  @impl true
  def init(_opts), do: {:ok, @idle}

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}

  def handle_call({:start_mirror, _key, _source}, _from, %{state: :running} = status) do
    {:reply, {:error, :busy}, status}
  end

  def handle_call({:start_mirror, space_key, source}, _from, _status) do
    status = %{@idle | state: :running, space_key: space_key}

    Task.Supervisor.start_child(ConfluencePhxMirror.Desktop.TaskSupervisor, fn ->
      source = source || Source.source()

      Mirror.mirror_space(space_key,
        source: source,
        on_page: fn done, total -> progress(done, total) end
      )
      |> finished()
    end)

    {:reply, {:ok, :started}, status}
  end

  @impl true
  def handle_cast({:progress, done, total}, status) do
    {:noreply, %{status | done: done, total: total}}
  end

  def handle_cast({:finished, {:ok, %{pages: count}}}, status) do
    {:noreply, %{status | state: :done, done: count, total: count}}
  end

  def handle_cast({:finished, {:error, reason}}, status) do
    {:noreply, %{status | state: :error, error: reason}}
  end
end
