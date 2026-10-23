defmodule ConfluencePhxMirror.Sync.Log do
  @moduledoc """
  The live log of what a sync is doing, as it does it.

  A snapshot of a real site copies hundreds of pages and files, and the only
  useful answer to "why is this page wrong?" is the line that mentions it. Those
  lines must not go into the audit log — an operator reading the audit log wants
  decisions, not copies — so they go here: a bounded, in-memory log that anyone
  can watch at `/admin/sync-log`.

  Every entry is broadcast on `topic/0` for open pages and kept in a ring buffer
  so a page opened mid-run still shows the last few hundred lines. The console
  gets the same entry through `Logger`, because a deployed mirror has no browser
  attached to it.

  A run's calls to Confluence are entries too (`kind: :http`), one line per
  attempt, so the page is a real stream of what went over the wire rather than
  a summary of it. They are written at `:debug`, which keeps them out of the
  console but in the page.
  """

  use GenServer

  require Logger

  @topic "sync:log"
  @limit 400

  @type level :: :debug | :info | :warn | :error

  @typedoc """
  What a line is about: the sync's own progress (`:sync`), one call to
  Confluence (`:http`), or the account of a run's calls (`:http_summary`).
  """
  @type kind :: :sync | :http | :http_summary

  @type entry :: %{
          id: integer(),
          at: DateTime.t(),
          level: level(),
          kind: kind(),
          message: String.t(),
          run_id: integer() | nil,
          details: map()
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The topic every new entry is broadcast on."
  def topic, do: @topic

  @doc """
  Records one line of sync activity.

  Returns `:ok` immediately: logging must never slow down or break a sync. The
  entry inherits the run that is in flight, so the page can group lines by run
  without the pipeline threading an id through every step.
  """
  @spec add(level(), String.t(), keyword() | map()) :: :ok
  def add(level, message, details \\ %{}) do
    details = Map.new(details)

    Logger.log(logger_level(level), message, Map.to_list(details))

    GenServer.cast(__MODULE__, {:append, level, message, details})
  end

  @doc "Marks the run its following lines belong to (or `nil` to end it)."
  @spec current_run(integer() | nil) :: :ok
  def current_run(run_id), do: GenServer.cast(__MODULE__, {:run, run_id})

  @doc "The entries kept in memory, newest last."
  @spec entries() :: [entry()]
  def entries, do: GenServer.call(__MODULE__, :entries)

  @doc "How many lines the log keeps; a page showing the tail shows this many."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc "Forgets everything kept in memory. The log is a view, not a record."
  @spec clear() :: :ok
  def clear, do: GenServer.cast(__MODULE__, :clear)

  @impl true
  def init(_opts), do: {:ok, %{entries: [], run_id: nil}}

  @impl true
  def handle_cast({:append, level, message, details}, state) do
    {kind, details} = Map.pop(details, :kind, :sync)

    entry = %{
      id: System.unique_integer([:monotonic, :positive]),
      at: DateTime.utc_now(),
      level: level,
      kind: kind,
      message: message,
      run_id: details[:sync_run_id] || state.run_id,
      details: Map.drop(details, [:sync_run_id, :message])
    }

    Phoenix.PubSub.broadcast(ConfluencePhxMirror.PubSub, @topic, {:sync_log, entry})

    {:noreply, %{state | entries: Enum.take(state.entries ++ [entry], -@limit)}}
  end

  def handle_cast({:run, run_id}, state), do: {:noreply, %{state | run_id: run_id}}
  def handle_cast(:clear, state), do: {:noreply, %{state | entries: []}}

  @impl true
  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  defp logger_level(:debug), do: :debug
  defp logger_level(:info), do: :info
  defp logger_level(:warn), do: :warning
  defp logger_level(:error), do: :error
end
