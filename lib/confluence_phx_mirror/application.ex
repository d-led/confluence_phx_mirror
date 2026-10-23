defmodule ConfluencePhxMirror.Application do
  @moduledoc false

  use Application

  require Logger

  alias ConfluencePhxMirror.Confluence.{HttpSource, RateLimiter}

  @impl true
  def start(_type, _args) do
    # A misspelt site skin should stop the release, not quietly serve the
    # default theme to everyone.
    ConfluencePhxMirrorWeb.Skins.validate_site_skin!()

    children = [
      ConfluencePhxMirrorWeb.Telemetry,
      ConfluencePhxMirror.Repo,
      ConfluencePhxMirror.Mirror.Counters,
      ConfluencePhxMirror.Sites.Guard,
      {DNSCluster,
       query: Application.get_env(:confluence_phx_mirror, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ConfluencePhxMirror.PubSub},
      ConfluencePhxMirrorWeb.Presence,
      ConfluencePhxMirror.RateLimit,
      rate_limiter_spec(),
      {Oban, Application.fetch_env!(:confluence_phx_mirror, Oban)},
      ConfluencePhxMirror.Sync.Log,
      ConfluencePhxMirror.Sync.Scheduler,
      ConfluencePhxMirrorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ConfluencePhxMirror.Supervisor]
    log_pool_size()
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ConfluencePhxMirrorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Logged here rather than in runtime.exs: that file is evaluated before Logger
  # starts, so a line written there is dropped. What a replica opens is the
  # number to multiply by the number of replicas to stay under max_connections
  # (see "Sizing the connection pool" in docs/operations.md).
  defp log_pool_size do
    config = Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Repo, [])
    pool_size = Keyword.get(config, :pool_size, 10)
    pool_count = Keyword.get(config, :pool_count, 1)

    Logger.info(
      "database pool: #{pool_size * pool_count} connections " <>
        "(#{pool_count} × #{pool_size})"
    )
  end

  defp rate_limiter_spec do
    config = Application.get_env(:confluence_phx_mirror, HttpSource, [])
    rate = Keyword.get(config, :requests_per_second, 5)
    burst = Keyword.get(config, :burst, max(trunc(rate), 1))

    {RateLimiter, requests_per_second: rate, burst: burst}
  end
end
