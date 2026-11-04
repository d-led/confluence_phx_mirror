defmodule ConfluencePhxMirror.Desktop.Web.Server do
  @moduledoc """
  The loopback listener the tool's window points at.

  It binds `127.0.0.1` and *prefers* one number, every launch, because the MCP
  endpoint is a URL a person pastes into an assistant once: `/api/mcp` on a port
  that changes per launch is a client that has to be re-pointed every time, which
  is not configured. The preference is, in order, `CONFLUENCE_EXPORT_PORT`, the
  `port` key in `settings.json`, and then 43_100 — the last of those is why the
  number is not 4_000 (a server) or 42_800 (the neighbouring Monty tool).

  A fixed port is also a port a second copy cannot have, so when it is taken — by
  another copy of this tool or by anything else — the operating system picks one
  instead and the announcement carries it, rather than the second copy being the
  one that fails to start.

  There is one listener and one origin. The mirror's own endpoint is mounted in
  it (see `ConfluencePhxMirror.Desktop.Web.Dispatch`), so every screen the
  server serves is served here too, at the same paths — the admin area included,
  and `/api/mcp` with them — and the tool's own few screens sit beside them under
  `/__tool`.
  """

  require Logger

  alias ConfluencePhxMirror.Desktop.Settings
  alias ConfluencePhxMirror.Desktop.Web.Dispatch

  @loopback {127, 0, 0, 1}

  @doc """
  The port this launch will try, before anything is bound.

  Asked before the endpoint starts, because the endpoint reads its own URL once,
  when it starts: a screen that generates an absolute link — the MCP page and its
  copy-paste block above all — needs the port the listener will actually get.
  """
  @spec choose_port() :: :inet.port_number()
  def choose_port do
    port = Settings.port()

    if free?(port), do: port, else: taken(port)
  end

  @doc """
  Whether a loopback port can be bound right now.

  Asked by opening and closing a socket, which is the only way to know a port is
  free before the listener that will use it exists. Nothing is held: Bandit owns
  the listen socket, and the moment between this answer and its bind is a loopback
  port on a machine running one tool.

  `reuseaddr: true` is not a detail to leave out: it is what ThousandIsland asks
  for, and without it this answers *taken* for a port the listener could have had.
  The sockets a session leaves behind are in `TIME_WAIT` on 127.0.0.1:43_100 for a
  minute after the window closes, and a plain `listen/2` refuses them with
  `:eaddrinuse` — so quitting and immediately reopening the tool used to move it to
  a random port, which is the one thing a fixed port is for. The option does not
  weaken the answer: two live listeners on one port need `reuseport`, not this.
  """
  @spec free?(:inet.port_number()) :: boolean()
  def free?(port) do
    case :gen_tcp.listen(port, ip: @loopback, active: false, reuseaddr: true) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  # A second copy has to start somewhere, and the port it wanted is the one thing
  # it cannot have.
  defp taken(port) do
    Logger.warning(
      "port #{port} is taken; asking the operating system for another one — " <>
        "the address is announced on stdout and shown behind the account menu"
    )

    {:ok, socket} = :gen_tcp.listen(0, ip: @loopback, active: false, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  @doc false
  # Bandit hands back its own supervisor, so this child is a supervisor too
  # rather than a worker — `restart: :permanent` and `:one_for_one` above it mean
  # the window is never served by a dead server.
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @doc "Starts the listener and returns the supervisor Bandit owns."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)

    with {:ok, supervisor} <- Bandit.start_link(plug: Dispatch, port: port, ip: @loopback) do
      bound = bound_port(supervisor, port)

      # The port that was actually granted, not the one that was preferred: the
      # MCP page, the configuration tool and the warning above all speak about the
      # address a client can reach, and a taken port makes those two different.
      Application.put_env(:confluence_phx_mirror, :desktop_port, bound)

      # The one thing that has to agree with the shell: the address, printed once,
      # on stdout, at boot (`src-tauri/src/main.rs` reads this line and nothing
      # else). Everything it says after that is a log.
      IO.puts("desktop ui: http://127.0.0.1:#{bound}/")
      {:ok, supervisor}
    end
  end

  # Bandit's supervisor holds a `:listener` child, which is the one process that
  # knows which port the socket actually got. `Supervisor.which_children/1`
  # rather than a name, because Bandit names nothing.
  #
  # `listener_info/1` answers `{{127,0,0,1}, 52534}` — the bound address and its
  # port, not a map, whatever the name suggests. The requested port is the
  # fallback for a Bandit that answers in a shape this does not know: it is what
  # was asked for, which is right whenever the OS honoured the request.
  defp bound_port(supervisor, requested) do
    with {_id, listener, _type, _modules} <-
           List.keyfind(Supervisor.which_children(supervisor), :listener, 0),
         {_address, port} when is_integer(port) <-
           ThousandIsland.Listener.listener_info(listener) do
      port
    else
      _unknown -> requested
    end
  end
end
