defmodule ConfluencePhxMirror.Application do
  @moduledoc false

  use Application

  alias ConfluencePhxMirror.Confluence.{HttpSource, RateLimiter}

  @impl true
  def start(_type, _args) do
    children = [
      ConfluencePhxMirrorWeb.Telemetry,
      ConfluencePhxMirror.Repo,
      {DNSCluster,
       query: Application.get_env(:confluence_phx_mirror, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ConfluencePhxMirror.PubSub},
      ConfluencePhxMirrorWeb.Presence,
      ConfluencePhxMirror.RateLimit,
      rate_limiter_spec(),
      {Oban, Application.fetch_env!(:confluence_phx_mirror, Oban)},
      ConfluencePhxMirror.Sync.Scheduler,
      ConfluencePhxMirrorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ConfluencePhxMirror.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ConfluencePhxMirrorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp rate_limiter_spec do
    config = Application.get_env(:confluence_phx_mirror, HttpSource, [])
    rate = Keyword.get(config, :requests_per_second, 5)
    burst = Keyword.get(config, :burst, max(trunc(rate), 1))

    {RateLimiter, requests_per_second: rate, burst: burst}
  end
end
