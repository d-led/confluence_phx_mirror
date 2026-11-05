defmodule ConfluencePhxMirror.Desktop.Web.ServerTest do
  @moduledoc """
  Which port a launch takes, which is the single-instance rule.

  Two copies of the tool are two servers, two job workers and two writers on one
  `catalogue.db`. The rule is: take the preferred port if it is free; step around
  it if something else holds it; refuse to start if what holds it is another copy
  of this app. The middle case matters as much as the third — a developer's
  machine has ports taken by other things all the time, and falling back is what
  the tool has always done.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Desktop.Web.{Dispatch, Server}

  # The marker `Dispatch` puts on its answers, which is what `choose_port/0` asks
  # a taken port for. A stub here rather than the real router only because this
  # test is about the *decision*; that the real router sets it is
  # `DispatchTest`'s job.
  defmodule Marked do
    @behaviour Plug

    import Plug.Conn, only: [put_resp_header: 3, send_resp: 3]

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn
      |> put_resp_header(Dispatch.instance_header(), "1")
      |> send_resp(200, "ok")
    end
  end

  setup do
    previous = System.get_env("CONFLUENCE_EXPORT_PORT")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("CONFLUENCE_EXPORT_PORT")
        port -> System.put_env("CONFLUENCE_EXPORT_PORT", port)
      end
    end)

    :ok
  end

  test "a free port is taken as it is" do
    port = free_port()
    System.put_env("CONFLUENCE_EXPORT_PORT", Integer.to_string(port))

    assert Server.choose_port() == {:ok, port}
  end

  test "a port something else holds is stepped around, not refused" do
    {:ok, holder} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    on_exit(fn -> :gen_tcp.close(holder) end)
    {:ok, taken} = :inet.port(holder)
    System.put_env("CONFLUENCE_EXPORT_PORT", Integer.to_string(taken))

    assert {:ok, port} = Server.choose_port()
    assert port != taken
  end

  test "a port another copy of this app answers on is refused, and said so in words" do
    # `start_supervised!`, not a link: ExUnit owns the lifetime, so nothing in an
    # `on_exit` has to race the test process's own shutdown.
    supervisor =
      start_supervised!({Bandit, plug: Marked, port: 0, ip: {127, 0, 0, 1}})

    port = bound_port(supervisor)
    System.put_env("CONFLUENCE_EXPORT_PORT", Integer.to_string(port))

    assert Server.choose_port() == {:error, :already_running}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp bound_port(supervisor) do
    # `Bandit` was asked for port 0, so the port it got is the one its listener
    # holds. The same call `Server.bound_port/2` makes at boot, so the test and
    # the app ask Bandit the same question.
    {_id, listener, _type, _modules} =
      List.keyfind(Supervisor.which_children(supervisor), :listener, 0)

    {_address, port} = ThousandIsland.Listener.listener_info(listener)
    port
  end
end
