defmodule ConfluencePhxMirror.Desktop.Web.Server do
  @moduledoc """
  The loopback server the tool's window points at.

  It binds 127.0.0.1 on an ephemeral port, so two copies of the tool on one
  machine never argue over a number, and nothing off this machine can reach it.
  The port is not configuration — it is whatever the OS granted — so it is
  printed once and kept: the shell reads it from the sidecar's output instead of
  guessing, which is the only part of the arrangement that has to agree.

  There is no `Endpoint` here, and no Phoenix router. What the tool serves is one
  form and one screen; borrowing the server's web layer would bring its sessions,
  its authentication and its admin with it.
  """

  alias ConfluencePhxMirror.Desktop.Web.Router

  @doc false
  # Bandit hands back its own supervisor, so this child is a supervisor too
  # rather than a worker — `restart: :permanent` and `:one_for_one` above it mean
  # the window is never served by a dead server.
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @doc "Starts the server and returns the supervisor Bandit owns."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    with {:ok, supervisor} <-
           Bandit.start_link(plug: Router, port: 0, ip: {127, 0, 0, 1}) do
      url = "http://127.0.0.1:#{bound_port(supervisor)}/"
      :persistent_term.put({__MODULE__, :url}, url)
      IO.puts("desktop ui: #{url}")
      {:ok, supervisor}
    end
  end

  @doc "The URL the window should open."
  @spec url() :: String.t()
  def url, do: :persistent_term.get({__MODULE__, :url})

  # Bandit's supervisor holds a `:listener` child, which is the one process that
  # knows which port the socket actually got. `Supervisor.which_children/1`
  # rather than a name, because Bandit names nothing.
  #
  # `listener_info/1` answers `{{127,0,0,1}, 52534}` — the bound address and its
  # port, not a map, whatever the name suggests.
  defp bound_port(supervisor) do
    {_id, listener, _type, _modules} =
      supervisor
      |> Supervisor.which_children()
      |> List.keyfind(:listener, 0)

    {_address, port} = ThousandIsland.Listener.listener_info(listener)

    port
  end
end
