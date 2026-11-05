defmodule ConfluencePhxMirror.Desktop.Spaces do
  @moduledoc """
  The space list, kept so the screen never waits on Confluence.

  Asking the source for every space is a network round trip — many of them, on a
  large site — and a request that blocks on it shows a person a blank window and
  no explanation. So the list is fetched in the background, held here, and
  served from memory; the screen says what is happening instead of hanging.

  What it holds is *a list from a source*, and both halves are kept. The tool
  boots on the bundled sample and switches to the site somebody configured, so a
  list fetched before that switch is the sample's two spaces — and a screen that
  drew them beside the real site's name, with a button that would mirror them, is
  the trap this module closes: an answer is served only while the source that
  produced it is still the configured one. Anything else is "still fetching",
  which the screen draws as a wait with no controls rather than as data.

  A refresh is never run twice at once: two of them would ask the same question
  of the same rate-limited API and arrive in an order nobody chose. The task is
  monitored for the same reason — a fetch that dies without answering would
  otherwise leave the list "loading" for ever, and every mirror start refused
  with it.
  """

  use GenServer

  alias ConfluencePhxMirror.Confluence.Source

  @type listing :: {:ok, [map()]} | :loading | {:error, term()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The list, or the news that it is still being fetched.

  `:loading` also covers a list that came from a source this workspace is no
  longer configured for: it is not an answer to the question being asked.

  Personal (`~account`) spaces are not in it unless the mirror is configured to
  take them (`CM_SYNC_PERSONAL_SPACES=true`, `Sync.personal_spaces?/0`). The
  deployment's picker never offers one, and a listing is what this tool's bulk
  button counts and enumerates — a personal space in the list was a personal
  space mirrored by a press meant for the site.
  """
  @spec list() :: listing()
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Whether the site lists `key` as somebody's personal space."
  @spec personal?(String.t()) :: boolean()
  def personal?(key) when is_binary(key), do: GenServer.call(__MODULE__, {:personal?, key})

  @doc "Whether a fetch is in flight, and whether a current list is held."
  @spec state() :: %{count: non_neg_integer(), refreshing?: boolean(), loaded?: boolean()}
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Re-reads the list from the source, in the background."
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
    :ok
  end

  @impl true
  def init(_opts) do
    # Nothing is fetched here. At this point the application has not loaded its
    # settings, so `Source.source/0` is still the bundled sample — and a list
    # fetched now would be the sample's spaces, drawn beside the real site and
    # offered for mirroring. `Desktop.Application.after_start/0` asks once the
    # workspace knows its site.
    {:ok, %{spaces: nil, source: nil, error: nil, refreshing?: false, task: nil}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, answer(state), state}

  def handle_call({:personal?, key}, _from, state) do
    personal =
      case state.spaces do
        nil -> false
        spaces -> Enum.any?(spaces, &(&1.key == key and personal_space?(&1)))
      end

    {:reply, personal, state}
  end

  def handle_call(:state, _from, state) do
    reply = %{
      count: length(offerable(state.spaces) || []),
      refreshing?: state.refreshing?,
      loaded?: current?(state)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_refresh(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, start_refresh(state)}

  def handle_info({:loaded, source, {:ok, spaces}}, state) do
    {:noreply, %{state | spaces: spaces, source: source, error: nil, refreshing?: false}}
  end

  def handle_info({:loaded, source, {:error, reason}}, state) do
    # A failed refresh keeps the list it already had — a site that is briefly
    # unreachable should not empty the screen somebody was working from — but
    # only if that list is the one this source produced. A failure with no list
    # is remembered with its source, so the screen can say what went wrong
    # instead of waiting for ever.
    spaces = if state.source == source, do: state.spaces, else: nil

    {:noreply, %{state | spaces: spaces, source: source, error: reason, refreshing?: false}}
  end

  # The task says `:loaded` before it exits, so this is normally only the exit.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    if reason == :normal do
      {:noreply, %{state | task: nil}}
    else
      {:noreply, %{state | task: nil, refreshing?: false, error: reason}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A list is an answer only while the source that produced it is still the one
  # this workspace is configured for. Boot fetches the bundled sample and a saved
  # connection swaps the source; without this the sample's spaces would be drawn
  # beside the real site — and offered for mirroring.
  defp current?(%{spaces: spaces, source: source}),
    do: spaces != nil and source == Source.source()

  # A current list, or the failure that explains why there is none, or "still
  # fetching" — in that order. An answer from a source this workspace is no
  # longer configured for is none of the three: it is the old question.
  defp answer(state) do
    cond do
      state.spaces != nil and state.source == Source.source() -> {:ok, offerable(state.spaces)}
      state.error != nil and state.source == Source.source() -> {:error, state.error}
      true -> :loading
    end
  end

  # What this window may offer: somebody's personal space is not one of them
  # unless the mirror is configured to take personal spaces at all.
  defp offerable(nil), do: nil

  defp offerable(spaces) do
    if ConfluencePhxMirror.Sync.personal_spaces?(),
      do: spaces,
      else: Enum.reject(spaces, &personal_space?/1)
  end

  defp personal_space?(space), do: Map.get(space, :type) == "personal"

  defp start_refresh(%{refreshing?: true} = state), do: state

  defp start_refresh(state) do
    parent = self()

    # The source is read inside the task and comes back with the answer, so what
    # is stored is *which* source produced this list — see `current?/1`.
    case Task.Supervisor.start_child(ConfluencePhxMirror.Desktop.TaskSupervisor, fn ->
           source = Source.source()
           send(parent, {:loaded, source, source.spaces([])})
         end) do
      {:ok, pid} ->
        %{state | refreshing?: true, task: Process.monitor(pid)}

      # Nothing was started, so nothing will answer. Saying "still fetching"
      # forever is the failure that looks like patience.
      {:error, reason} ->
        %{state | error: reason, refreshing?: false}
    end
  end
end
