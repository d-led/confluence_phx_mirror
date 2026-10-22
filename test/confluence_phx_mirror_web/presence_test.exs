defmodule ConfluencePhxMirrorWeb.PresenceTest do
  use ConfluencePhxMirror.DataCase, async: false

  import Phoenix.ChannelTest

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.PageChannel
  alias ConfluencePhxMirrorWeb.Presence
  alias ConfluencePhxMirrorWeb.UserSocket

  @endpoint ConfluencePhxMirrorWeb.Endpoint

  setup do
    on_exit(fn ->
      Presence.untrack(self(), Presence.topic(1002), "user:1")
      Presence.untrack(self(), Presence.topic(1002), "user:2")
    end)

    :ok
  end

  test "counts readers per page topic" do
    assert Presence.count(1002) == 0

    {:ok, _} = Presence.track(self(), Presence.topic(1002), "user:1", %{user: "jane"})
    {:ok, _} = Presence.track(self(), Presence.topic(1002), "user:2", %{user: "sam"})

    assert Presence.count(1002) == 2
    assert Presence.count(1003) == 0
  end

  test "joining the page channel tracks the reader" do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    page = Mirror.get_page!(1002)

    socket = socket(UserSocket, nil, %{})

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, PageChannel, Presence.topic(page.confluence_id))

    assert Presence.count(1002) == 1

    assert Presence.list(Presence.topic(1002))
           |> Enum.any?(fn {_key, %{metas: metas}} -> metas != [] end)
  end

  test "a restricted page cannot be joined, so its readers stay unlisted" do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    page = Mirror.get_page!(1003)

    socket = socket(UserSocket, nil, %{})

    assert {:error, %{reason: "page_not_found"}} =
             subscribe_and_join(socket, PageChannel, Presence.topic(page.confluence_id))

    assert Presence.count(1003) == 0
  end

  test "joining an unknown page is rejected" do
    socket = socket(UserSocket, nil, %{})

    assert {:error, %{reason: "page_not_found"}} =
             subscribe_and_join(socket, PageChannel, "page:999999")
  end
end
