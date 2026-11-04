defmodule ConfluencePhxMirror.Desktop.Jobs do
  @moduledoc """
  The one mirror run the tool can have going at a time, over one space or many.

  A single user with a single catalogue has no reason to run two mirrors
  concurrently, and every reason not to: they would write the same rows and
  compete for the same rate limit. So this holds one run, refuses a second, and
  answers the screen's question — what is happening, and how far along.

  A run is a *list* of spaces, because "mirror everything" is what a person
  reaches for first on a site with a hundred thousand of them. One space is a
  list of one, so there is no second code path to keep in step.

  The work runs under the task supervisor rather than in this process, so a slow
  space never blocks the web server showing its progress.
  """

  use GenServer

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Desktop.Mirror

  @type state :: :idle | :running | :done | :error

  @type status :: %{
          state: state(),
          label: String.t() | nil,
          index: non_neg_integer(),
          count: non_neg_integer(),
          done: non_neg_integer(),
          total: non_neg_integer(),
          error: term(),
          task: reference() | nil
        }

  @idle %{
    state: :idle,
    label: nil,
    index: 0,
    count: 0,
    done: 0,
    total: 0,
    error: nil,
    task: nil
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "What the mirror is doing, for the screen that follows it."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Mirrors `space_keys` in order, under `label`.

  Answers `{:error, :busy}` when a run is already going, and
  `{:error, :nothing_to_do}` when there is nothing to mirror.
  """
  @spec start_mirror([String.t()], String.t(), keyword()) ::
          {:ok, :started} | {:error, :busy | :nothing_to_do | :no_worker}
  def start_mirror(space_keys, label, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:start, space_keys, label, Keyword.get(opts, :source), run_options(opts)}
    )
  end

  # What a run is told about itself. `remember: false` is a bulk run: it copies
  # what the workspace is configured for and does not decide the configuration.
  defp run_options(opts) do
    if Keyword.get(opts, :remember, true), do: [], else: [remember: false]
  end

  @doc false
  def progress(done, total), do: GenServer.cast(__MODULE__, {:progress, done, total})

  @doc false
  def entering(index), do: GenServer.cast(__MODULE__, {:entering, index})

  @doc false
  def finished(result), do: GenServer.cast(__MODULE__, {:finished, result})

  @impl true
  def init(_opts), do: {:ok, @idle}

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}

  def handle_call({:start, _keys, _label, _source, _opts}, _from, %{state: :running} = status) do
    {:reply, {:error, :busy}, status}
  end

  def handle_call({:start, [], _label, _source, _opts}, _from, status) do
    {:reply, {:error, :nothing_to_do}, status}
  end

  def handle_call({:start, keys, label, source, opts}, _from, _status) do
    status = %{@idle | state: :running, label: label, count: length(keys)}

    # `async_nolink` rather than a bare child: a run that raises never reaches
    # `finished/1`, and a screen stuck on "Mirroring" is a tool that refuses
    # every later run with `:busy` and cannot be used again without a restart.
    # The monitor is what turns a crash into an answer.
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(ConfluencePhxMirror.Desktop.TaskSupervisor, fn ->
        run(keys, source || Source.source(), opts)
      end)

    {:reply, {:ok, :started}, %{status | task: ref}}
  end

  # The run's own last word, and then its exit. A run that ended normally has
  # already said `:done` or `:error` through `finished/1`, so this only clears the
  # reference; anything else died before it could speak.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = status) do
    status = %{status | task: nil}

    if reason == :normal,
      do: {:noreply, status},
      else: {:noreply, %{status | state: :error, error: reason}}
  end

  # The supervisor sends nothing else, but a GenServer that dies on an unexpected
  # message is a worse failure than one that ignores it: this process is the only
  # thing the mirror screen asks about a run.
  def handle_info(_message, status), do: {:noreply, status}

  @impl true
  def handle_cast({:progress, done, total}, status) do
    {:noreply, %{status | done: done, total: total}}
  end

  def handle_cast({:entering, index}, status) do
    # The page counter belongs to the space that just finished, not the one
    # starting, so it goes back to nothing rather than reading as progress.
    {:noreply, %{status | index: index, done: 0, total: 0}}
  end

  def handle_cast({:finished, :ok}, status) do
    {:noreply, %{status | state: :done}}
  end

  def handle_cast({:finished, {:error, reason}}, status) do
    {:noreply, %{status | state: :error, error: reason}}
  end

  # Sequential on purpose: the source is rate limited, and two spaces at once
  # would only make the limit bind sooner.
  defp run(keys, source, opts) do
    result =
      keys
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {key, index}, :ok ->
        entering(index)

        case Mirror.mirror_space(key, [source: source, on_page: &progress/2] ++ opts) do
          {:ok, _space} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {key, reason}}}
        end
      end)

    finished(result)
  end
end
