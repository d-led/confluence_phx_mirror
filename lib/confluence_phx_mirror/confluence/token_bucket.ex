defmodule ConfluencePhxMirror.Confluence.TokenBucket do
  @moduledoc """
  Pure token bucket used for client-side rate limiting.

  Time is passed in by the caller, which keeps the maths testable and lets the
  GenServer own sleeping. The bucket allows controlled bursts up to `burst`
  and refills at `rate` tokens per second.
  """

  defstruct rate: 1.0, burst: 1.0, tokens: 1.0, last_ms: 0

  @type t :: %__MODULE__{rate: float(), burst: float(), tokens: float(), last_ms: integer()}

  @doc "A full bucket that allows `burst` immediate requests."
  def new(rate, burst, now_ms) when rate > 0 and burst >= 1 do
    %__MODULE__{rate: rate * 1.0, burst: burst * 1.0, tokens: burst * 1.0, last_ms: now_ms}
  end

  @doc """
  Takes one token.

  Returns `{:ok, bucket}` when a request may proceed now, or
  `{:wait, milliseconds, bucket}` with the time until the next token.
  """
  @spec take(t(), integer()) :: {:ok, t()} | {:wait, pos_integer(), t()}
  def take(%__MODULE__{} = bucket, now_ms) do
    bucket = refill(bucket, now_ms)

    if bucket.tokens >= 1.0 do
      {:ok, %{bucket | tokens: bucket.tokens - 1.0}}
    else
      wait_ms = ceil((1.0 - bucket.tokens) / bucket.rate * 1000)
      {:wait, max(wait_ms, 1), bucket}
    end
  end

  defp refill(bucket, now_ms) do
    elapsed_ms = max(now_ms - bucket.last_ms, 0)
    tokens = min(bucket.burst, bucket.tokens + elapsed_ms / 1000 * bucket.rate)
    %{bucket | tokens: tokens, last_ms: now_ms}
  end
end
