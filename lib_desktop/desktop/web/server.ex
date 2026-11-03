defmodule ConfluencePhxMirror.Desktop.Web.Server do
  @moduledoc """
  The loopback listener the tool's window points at.

  It binds `127.0.0.1` on an ephemeral port, so two copies of the tool on one
  machine never argue over a number and nothing off this machine can reach it.
  The port is not configuration — it is whatever the OS granted — so it is
  printed once and kept: the shell reads it from the sidecar's output instead of
  guessing, which is the only part of the arrangement that has to agree.

  There is one listener and one origin. The mirror's own endpoint is mounted in
  it (see `ConfluencePhxMirror.Desktop.Web.Dispatch`), so every screen the
  server serves is served here too, at the same paths — the admin area included
  — and the tool's own few screens sit beside them under `/__tool`.
  """

  alias ConfluencePhxMirror.Desktop.Web.Dispatch

  @doc """
  A port that is free right now.

  Asked before the endpoint starts, because the endpoint reads its own URL once,
  when it starts: a screen that generates an absolute link needs the port the
  listener will actually get. The socket is opened and closed rather than held,
  because Bandit wants to own the listen socket — the window between the two is
  a loopback port on a machine running one tool.
  """
  @spec choose_port() :: :inet.port_number()
  def choose_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
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

    with {:ok, supervisor} <- Bandit.start_link(plug: Dispatch, port: port, ip: {127, 0, 0, 1}) do
      # The one thing that has to agree with the shell: the address, printed once,
      # on stdout, at boot (`src-tauri/src/main.rs` reads this line and nothing
      # else). Everything it says after that is a log.
      IO.puts("desktop ui: http://127.0.0.1:#{bound_port(supervisor, port)}/")
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
