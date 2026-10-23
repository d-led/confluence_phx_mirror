defmodule ConfluencePhxMirrorWeb.UserSocketTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  require Phoenix.ChannelTest

  alias ConfluencePhxMirrorWeb.UserSocket

  # Qualified, because `ConnCase` also imports `Plug.Conn.connect/3`.
  defp connect_socket(info), do: Phoenix.ChannelTest.connect(UserSocket, %{}, info)

  test "connects a signed-in reader and exposes the id presence uses" do
    user = user_fixture(%{email: "socket.reader@example.com"})

    assert {:ok, socket} = connect_socket(connect_info: %{session: %{"user_id" => user.id}})
    assert socket.assigns.user_id == user.id
    assert socket.assigns.user_email == "socket.reader@example.com"
    assert socket.assigns.reader_key == "user:#{user.id}"
    assert UserSocket.id(socket) == "user:#{user.id}"
  end

  test "connects anonymously when the session has no user" do
    assert {:ok, socket} = connect_socket(connect_info: %{session: %{}})
    assert socket.assigns.user_id == nil
    assert UserSocket.id(socket) == nil
  end

  test "each anonymous connection is its own reader" do
    assert {:ok, first} = connect_socket(connect_info: %{session: %{}})
    assert {:ok, second} = connect_socket(connect_info: %{session: %{}})

    assert first.assigns.reader_key =~ ~r/^reader:/
    refute first.assigns.reader_key == second.assigns.reader_key
  end

  test "refuses a connection that carries no session at all" do
    assert :error == Phoenix.ChannelTest.connect(UserSocket, %{}, connect_info: %{})
  end
end
