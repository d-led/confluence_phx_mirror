defmodule ConfluencePhxMirror.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ConfluencePhxMirrorWeb.Telemetry,
      ConfluencePhxMirror.Repo,
      {DNSCluster,
       query: Application.get_env(:confluence_phx_mirror, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ConfluencePhxMirror.PubSub},
      # Start a worker by calling: ConfluencePhxMirror.Worker.start_link(arg)
      # {ConfluencePhxMirror.Worker, arg},
      # Start to serve requests, typically the last entry
      ConfluencePhxMirrorWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ConfluencePhxMirror.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConfluencePhxMirrorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
