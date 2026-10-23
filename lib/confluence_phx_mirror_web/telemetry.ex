defmodule ConfluencePhxMirrorWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  alias ConfluencePhxMirror.Mirror

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      #
      # `init_delay` keeps the first poll out of the boot: the poller measures
      # as soon as it starts, and a measurement that raises is dropped for the
      # life of the node.
      {:telemetry_poller,
       measurements: periodic_measurements(), period: 10_000, init_delay: 5_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("confluence_phx_mirror.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("confluence_phx_mirror.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("confluence_phx_mirror.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("confluence_phx_mirror.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("confluence_phx_mirror.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Mirror Metrics
      #
      # Two shapes, because two questions. `last_value` answers "how much is
      # there right now", which the poller samples; `counter` answers "how
      # often has this happened", which the request itself reports.
      last_value("confluence_mirror.catalogue.pages",
        unit: :page,
        description: "Pages the mirror holds"
      ),
      last_value("confluence_mirror.catalogue.spaces",
        unit: :space,
        description: "Spaces the mirror holds"
      ),
      last_value("confluence_mirror.catalogue.attachments",
        unit: :attachment,
        description: "Attachments the mirror holds"
      ),
      counter("confluence_mirror.page.view.count",
        tags: [:kind],
        description: "Pages a reader opened (a 304 revalidation is not one)"
      )
    ]
  end

  @doc """
  Publishes what the mirror holds, so the catalogue can be charted over time.

  Called by the poller rather than by a request: the totals move when a sync
  writes, which is not an event this process sees. The counting itself is
  cached against the content's version (`Mirror.Counters`), so a quiet mirror
  answers with its existing totals instead of scanning.
  """
  def measure_catalogue do
    %{pages: pages, spaces: spaces, attachments: attachments} = Mirror.stats()

    :telemetry.execute(
      [:confluence_mirror, :catalogue],
      %{pages: pages, spaces: spaces, attachments: attachments},
      %{}
    )
  end

  # Polled measurements are the ones with no event to hook: a gauge needs a
  # value even when nothing happens. Only where someone is watching, because
  # each poll asks the database — and the test suite runs without a sandbox
  # around a background process.
  defp periodic_measurements do
    if Application.get_env(:confluence_phx_mirror, :catalogue_metrics, false) do
      [{__MODULE__, :measure_catalogue, []}]
    else
      []
    end
  end
end
