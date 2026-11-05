defmodule ConfluencePhxMirror.Desktop.Application do
  @moduledoc """
  What the export tool starts: the server's own application tree, over one
  folder on one machine.

  The tool *is* the server. Its screens are the mirror's screens — the same
  LiveViews, the same admin area, the same settings page an operator changes a
  theme on — served by the same endpoint and the same router. What differs is
  what those screens are pointed at: a SQLite catalogue under the user's data
  directory instead of a Postgres one behind a load balancer, and a reader who
  is already an administrator, because the window is the only way in.

  So this list is the server's list, less what has nothing to coordinate here:

    * `DNSCluster` — there is one node, and it has no peers.
    * the two `Sync.Scheduler` clocks — the tool mirrors when somebody presses
      the button, not on an interval nobody set. `/admin/settings` still shows
      the interval; nothing here reads it.
    * `Sync.StartupPull` — the same reason, and because a first run has no
      credentials yet: it would queue a pull that can only fail.

  Everything else is here, including what the admin screens ask for:
  `Mirror.Counters` for the totals, `MetricsHistory` for the charts,
  `Sites.Guard` for the site check, `Oban` for the job list.
  """

  use Application

  alias ConfluencePhxMirror.Desktop.{Settings, Setup}
  alias ConfluencePhxMirror.Desktop.Web.Server

  @impl true
  def start(_type, _args) do
    # A misspelt skin name should stop the release, not quietly serve the
    # default theme to everyone.
    ConfluencePhxMirrorWeb.Skins.validate!()

    # Before the repo: the store resolves its root on use, and the repo reads its
    # path from here as it starts.
    Settings.apply_runtime_config()

    # Before anything touches the catalogue: a second copy has to be turned away
    # *here*, not after it has spent five seconds on a lock another copy holds and
    # then reported that as a crash. The port is a read of the environment and
    # `settings.json` — nothing the database answers — so asking it first costs
    # nothing.
    #
    # The port is chosen before the endpoint starts for the older reason too: the
    # endpoint reads its URL once, when it starts, and a screen generated with
    # yesterday's port in it is a link to nowhere.
    #
    # `:already_running` is a refusal, not a crash: another copy of this app holds
    # the port and the one catalogue behind it, and two writers on one SQLite file
    # is a fight rather than a feature. It is answered in words here, because the
    # window shows the release's own output and a crash term is not words.
    case Server.choose_port() do
      {:ok, port} ->
        # A catalogue written by an earlier build cannot be migrated onto the
        # shared schema, and the rename this does cannot happen underneath an open
        # connection — so it happens here, before there is one.
        Setup.prepare(Settings.database())

        put_endpoint_config(port)
        start_children(port)

      {:error, :already_running} ->
        IO.puts(:stderr, """
        Confluence Export is already running: another copy of this app is
        answering on port #{Settings.port()}.

        One workspace has one catalogue, and two copies would write it at the
        same time. Close the window of the copy that is already open — the app
        quits when its window closes — and start this one again.

        If that copy is gone and the port is still answered, something else on
        this machine is listening there: set CONFLUENCE_EXPORT_PORT, or "port"
        in settings.json, to another number.
        """)

        # `halt`, not a failed `start/2`: nothing has been opened yet — no
        # connection, no migration, no write — so there is nothing to unwind, and
        # a returned error would raise a supervision failure whose log is a crash
        # term plus an `erl_crash.dump` beside it. A person needs the paragraph
        # above; the exit status tells a script the copy did not start.
        System.halt(1)
    end
  end

  defp start_children(port) do
    children = [
      ConfluencePhxMirror.Repo,
      # Straight after the repo and before anything that queries it: a supervisor
      # starts its children in order, and this one does its work in `start_link`.
      # A fresh install has no tables until it has run.
      ConfluencePhxMirror.Desktop.Setup,
      # LiveView's transport and the mirror's own broadcasts. Without it every
      # `mount` that subscribes fails.
      {Phoenix.PubSub, name: ConfluencePhxMirror.PubSub},
      # The totals the home page shows, and the gauges the admin overview does.
      ConfluencePhxMirror.Mirror.Counters,
      ConfluencePhxMirror.MetricsHistory,
      ConfluencePhxMirror.Resources,
      ConfluencePhxMirrorWeb.Telemetry,
      # A window has a person in front of it and no console, so a disagreement
      # with its folder is reported and shown rather than raised: what a crash
      # dump explains to nobody is which site the folder belongs to. Syncing
      # still refuses per run, and `Sync` is where `verify!/0` is called.
      {ConfluencePhxMirror.Sites.Guard, on_conflict: :report},
      ConfluencePhxMirror.Mcp.Markdown,
      ConfluencePhxMirror.SpaceDirectory,
      # The archive builder: one build at a time, and a file on disk before
      # anyone downloads it. The server's own, so what the tool hands over is
      # byte for byte what the deployment hands over.
      {Task.Supervisor, name: ConfluencePhxMirror.Export.TaskSupervisor},
      ConfluencePhxMirror.Export.Artifact,
      ConfluencePhxMirrorWeb.Presence,
      # The reader limits the browser pipeline applies, and the client-side
      # limit the source applies to us.
      ConfluencePhxMirror.RateLimit,
      rate_limiter_spec(),
      ConfluencePhxMirror.Confluence.Traffic,
      # The job list `/admin` and `/admin/jobs` read, on the engine SQLite has.
      {Oban, Application.fetch_env!(:confluence_phx_mirror, Oban)},
      ConfluencePhxMirror.Sync.Log,
      ConfluencePhxMirror.Sync.Runs,
      {Task.Supervisor, name: ConfluencePhxMirror.Desktop.TaskSupervisor},
      # The space list the picker chooses from. The mirror run itself is not a
      # process of its own: it is a job on the `sync` queue below, where it has a
      # row, a gate and a cancel like any other run.
      ConfluencePhxMirror.Desktop.Spaces,
      # `server: false`: the listener below is the one that accepts connections,
      # and the endpoint is mounted in it. Everything else the endpoint owns —
      # the configuration cache, the socket transports, the static manifest —
      # is started here and used there.
      ConfluencePhxMirrorWeb.Endpoint,
      # Last, so the window it advertises is only reachable once every screen it
      # serves has what it needs.
      {ConfluencePhxMirror.Desktop.Web.Server, port: port}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: name()) do
      {:ok, pid} ->
        after_start()
        {:ok, pid}

      error ->
        error
    end
  end

  defp name, do: ConfluencePhxMirror.Desktop.Supervisor

  # What the server does once its tree is up, in the same order and for the same
  # reasons: one log line per request, the settings an administrator saved read
  # once so a per-request theme lookup never queries the database, and a job left
  # `executing` by the last shutdown settled before anything asks about it.
  defp after_start do
    ConfluencePhxMirrorWeb.Telemetry.RequestLog.attach()
    ConfluencePhxMirror.Settings.load()
    ConfluencePhxMirror.SiteSettings.load()
    ConfluencePhxMirror.Mailer.configure()

    # The token is read from the OS credential store, which is allowed to ask a
    # question and wait — macOS does exactly that the first time an application it
    # does not know reads the item, and a copy in `/Applications` is such an
    # application. Here, the dialog has a window behind it, because the listener
    # above has already printed the address the window is opened on.
    Settings.adopt_legacy_secret()
    Settings.apply_credentials()

    # And now the space list, which needs both: the source is the site's only
    # after the settings are loaded, and asking before that fetched the bundled
    # sample's spaces and then drew them beside the real site's name.
    ConfluencePhxMirror.Desktop.Spaces.refresh()

    ConfluencePhxMirror.Sync.abandon_abandoned_runs()

    watch_parent()
  end

  # The window owns this process. When its end of the pipe closes — the window was
  # force-quit, crashed, or killed — there is nothing left to serve and nobody
  # left to ask it to stop, so it stops itself and gives the port back to the next
  # launch. Without this a window that died leaves a server holding the port and a
  # database open, which is a tool that "will not start" the second time.
  #
  # Only when the window asked for it: a release started from a shell inherits a
  # stdin that may already be at end-of-file, and must not exit over it.
  defp watch_parent do
    if System.get_env("CONFLUENCE_EXPORT_DIE_WITH_PARENT") == "1" do
      spawn(fn -> await_end_of_input() end)
    end

    :ok
  end

  defp await_end_of_input do
    case IO.read(:stdio, :line) do
      :eof -> System.stop(0)
      {:error, _reason} -> System.stop(0)
      _a_line_nobody_writes -> await_end_of_input()
    end
  end

  defp rate_limiter_spec do
    source = ConfluencePhxMirror.Confluence.HttpSource
    config = Application.get_env(:confluence_phx_mirror, source, [])
    rate = Keyword.get(config, :requests_per_second, 5)
    burst = Keyword.get(config, :burst, max(trunc(rate), 1))

    {ConfluencePhxMirror.Confluence.RateLimiter, requests_per_second: rate, burst: burst}
  end

  # Where the screens think they are served from, and what signs the one session
  # they keep. The endpoint reads both once, when it starts, so they are written
  # before the supervisor starts — and the port is the one the listener below is
  # given, not a guess.
  #
  # The signing salt is generated per launch rather than configured, because a
  # constant in a repository is a secret in a repository and this deployment has
  # nobody to fetch one from. Nothing is lost: the session belongs to the process
  # serving it, and `:auto_admin` establishes the reader again on the next
  # request, so a cookie from the last launch being unreadable changes nothing.
  defp put_endpoint_config(port) do
    endpoint = ConfluencePhxMirrorWeb.Endpoint
    current = Application.get_env(:confluence_phx_mirror, endpoint, [])

    Application.put_env(
      :confluence_phx_mirror,
      endpoint,
      Keyword.merge(current,
        url: [host: "127.0.0.1", port: port, scheme: "http"],
        http: [ip: {127, 0, 0, 1}, port: port],
        server: false,
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48))
      )
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    ConfluencePhxMirrorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
