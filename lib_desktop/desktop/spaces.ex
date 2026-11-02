defmodule ConfluencePhxMirror.Desktop.Spaces do
  @moduledoc """
  The space list, kept so the screen never waits on Confluence.

  Asking the source for every space is a network round trip — many of them, on a
  large site — and a request that blocks on it shows a person a blank window and
  no explanation. So the list is fetched in the background, held here, and
  served from memory; the screen says what is happening instead of hanging.

  A refresh is never run twice at once: two of them would ask the same question
  of the same rate-limited API and arrive in an order nobody chose.
  """

  use GenServer

  alias ConfluencePhxMirror.Desktop.Mirror

  @type listing :: {:ok, [map()]} | :loading | {:error, term()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The list, or the news that it is still being fetched."
  @spec list() :: listing()
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Whether a fetch is in flight, and how much is known."
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
    # Fetched at boot, so the first visit to the screen is already warm.
    send(self(), :refresh)
    {:ok, %{spaces: nil, error: nil, refreshing?: false}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, answer(state), state}
  end

  def handle_call(:state, _from, state) do
    reply = %{
      count: length(state.spaces || []),
      refreshing?: state.refreshing?,
      loaded?: state.spaces != nil
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_refresh(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, start_refresh(state)}

  def handle_info({:loaded, {:ok, spaces}}, state) do
    {:noreply, %{state | spaces: spaces, error: nil, refreshing?: false}}
  end

  def handle_info({:loaded, {:error, reason}}, state) do
    # A failed refresh keeps the list it already had: a site that is briefly
    # unreachable should not empty the screen somebody was working from.
    {:noreply, %{state | error: reason, refreshing?: false}}
  end

  defp answer(%{spaces: nil, error: nil}), do: :loading
  defp answer(%{spaces: nil, error: error}), do: {:error, error}
  defp answer(%{spaces: spaces}), do: {:ok, spaces}

  defp start_refresh(%{refreshing?: true} = state), do: state

  defp start_refresh(state) do
    parent = self()

    Task.Supervisor.start_child(ConfluencePhxMirror.Desktop.TaskSupervisor, fn ->
      send(parent, {:loaded, Mirror.spaces()})
    end)

    %{state | refreshing?: true}
  end
end
