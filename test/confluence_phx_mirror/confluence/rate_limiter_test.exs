defmodule ConfluencePhxMirror.Confluence.RateLimiterTest do
  @moduledoc """
  The client-side limiter reports the time it made a call wait, so the sync log
  can show throttling on the call's own line.
  """
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Confluence.RateLimiter

  test "the limiter the application starts runs at the configured pace" do
    configured =
      :confluence_phx_mirror
      |> Application.get_env(HttpSource, [])
      |> Keyword.fetch!(:requests_per_second)

    assert %{bucket: %{rate: rate}} = RateLimiter.state()
    assert rate == configured * 1.0
  end

  test "a call with a free token does not wait" do
    start_supervised!({RateLimiter, name: __MODULE__.Quick, requests_per_second: 1_000, burst: 1})

    assert {:ok, 0} = RateLimiter.acquire(__MODULE__.Quick)
  end

  test "a call that has to wait for a token says how long it waited" do
    start_supervised!({RateLimiter, name: __MODULE__.Slow, requests_per_second: 20, burst: 1})

    assert {:ok, 0} = RateLimiter.acquire(__MODULE__.Slow)
    assert {:ok, waited_ms} = RateLimiter.acquire(__MODULE__.Slow)
    assert waited_ms > 0
  end

  test "without a running limiter nothing is throttled" do
    assert {:ok, 0} = RateLimiter.acquire(__MODULE__.NotRunning)
  end
end
