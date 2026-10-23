defmodule ConfluencePhxMirror.Confluence.RateLimiter do
  @moduledoc """
  Site-wide, client-side rate limiter for requests to Confluence.

  Confluence Cloud enforces its own API limits; hammering it during a full
  snapshot gets the mirror throttled or banned. Every HTTP request the source
  makes first calls `acquire/0`, which blocks until the token bucket has a free
  token. The rate is configurable (`CM_REQUESTS_PER_SECOND`, `CM_BURST`).

  When the limiter is not running (demo source, tests) `acquire/0` is a no-op
  that reports a zero wait.
  """

  use GenServer

  alias ConfluencePhxMirror.Confluence.TokenBucket

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Blocks until one request may be sent.

  Returns how long the call had to wait for a free token, so the client can
  report throttling on the request's own log line instead of somewhere else.
  """
  @spec acquire(GenServer.server()) :: {:ok, non_neg_integer()}
  def acquire(server \\ @name) do
    case GenServer.whereis(server) do
      nil -> {:ok, 0}
      pid -> GenServer.call(pid, :acquire, :infinity)
    end
  end

  @doc "Current bucket state, useful for diagnostics."
  def state(server \\ @name) do
    case GenServer.whereis(server) do
      nil -> nil
      pid -> GenServer.call(pid, :state)
    end
  end

  @impl true
  def init(opts) do
    rate = Keyword.get(opts, :requests_per_second, 5)
    burst = Keyword.get(opts, :burst, max(trunc(rate), 1))

    {:ok, %{bucket: TokenBucket.new(rate, burst, now_ms())}}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    {waited_ms, state} = acquire_token(state, 0)
    {:reply, {:ok, waited_ms}, state}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  defp acquire_token(state, waited_ms) do
    case TokenBucket.take(state.bucket, now_ms()) do
      {:ok, bucket} ->
        {waited_ms, %{state | bucket: bucket}}

      {:wait, wait_ms, bucket} ->
        Process.sleep(wait_ms)
        acquire_token(%{state | bucket: bucket}, waited_ms + wait_ms)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @name),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end
