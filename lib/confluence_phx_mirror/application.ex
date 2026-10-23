defmodule ConfluencePhxMirror.Application do
  @moduledoc false

  use Application

  require Logger

  alias ConfluencePhxMirror.BuildInfo
  alias ConfluencePhxMirror.Confluence.{HttpSource, RateLimiter}

  @impl true
  def start(_type, _args) do
    # A misspelt skin name should stop the release, not quietly serve the
    # default theme to everyone.
    ConfluencePhxMirrorWeb.Skins.validate!()

    children = [
      ConfluencePhxMirror.Repo,
      ConfluencePhxMirror.Mirror.Counters,
      # After the repo and the counters: the first poll runs as soon as the
      # poller starts, and the catalogue gauge has to ask the database.
      ConfluencePhxMirrorWeb.Telemetry,
      ConfluencePhxMirror.Sites.Guard,
      {DNSCluster,
       query: Application.get_env(:confluence_phx_mirror, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ConfluencePhxMirror.PubSub},
      ConfluencePhxMirrorWeb.Presence,
      ConfluencePhxMirror.RateLimit,
      rate_limiter_spec(),
      ConfluencePhxMirror.Confluence.Traffic,
      {Oban, Application.fetch_env!(:confluence_phx_mirror, Oban)},
      ConfluencePhxMirror.Sync.Log,
      ConfluencePhxMirror.Sync.Scheduler,
      ConfluencePhxMirrorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ConfluencePhxMirror.Supervisor]
    log_pool_size()
    # Said once, at boot: which build this is, so a log from a container that
    # started for someone else's deploy can be identified.
    log_build()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # One log line per request, none for the health probes: Phoenix's own
        # request logger is off in `config :phoenix, :logger`.
        ConfluencePhxMirrorWeb.Telemetry.RequestLog.attach()

        # Settings an administrator changed are read from the table once, so
        # the per-request theme lookup never queries the database.
        ConfluencePhxMirror.Settings.load()
        {:ok, pid}

      error ->
        error
    end
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

  defp log_build do
    Logger.info("build: #{BuildInfo.description()}")
  end

  defp rate_limiter_spec do
    config = Application.get_env(:confluence_phx_mirror, HttpSource, [])
    rate = Keyword.get(config, :requests_per_second, 5)
    burst = Keyword.get(config, :burst, max(trunc(rate), 1))

    {RateLimiter, requests_per_second: rate, burst: burst}
  end
end
