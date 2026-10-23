defmodule ConfluencePhxMirrorWeb.PresenceTest do
  use ConfluencePhxMirror.DataCase, async: false

  import Phoenix.ChannelTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.PageChannel
  alias ConfluencePhxMirrorWeb.Presence
  alias ConfluencePhxMirrorWeb.SiteChannel
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

    socket = socket(UserSocket, nil, %{reader_key: "reader:1", scope: anonymous()})

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, PageChannel, Presence.topic(page.confluence_id))

    assert Presence.count(1002) == 1

    assert Presence.list(Presence.topic(1002))
           |> Enum.any?(fn {_key, %{metas: metas}} -> metas != [] end)
  end

  test "a restricted page cannot be joined, so its readers stay unlisted" do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    page = Mirror.get_page!(Demo.restricted_page())

    socket = socket(UserSocket, nil, %{reader_key: "reader:1", scope: anonymous()})

    assert {:error, %{reason: "page_not_found"}} =
             subscribe_and_join(socket, PageChannel, Presence.topic(page.confluence_id))

    assert Presence.count(page.confluence_id) == 0
  end

  test "a reader the page is shared with may join it and is counted" do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    page = Mirror.get_page!(Demo.restricted_page())
    user = reader_in_group(Demo.page_readers())

    socket =
      socket(UserSocket, "user:#{user.id}", %{
        reader_key: "user:#{user.id}",
        user_id: user.id,
        user_name: user.display_name,
        scope: Scope.for_user(user)
      })

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket, PageChannel, Presence.topic(page.confluence_id))

    assert Presence.count(page.confluence_id) == 1
  end

  test "a signed-in reader the page is not shared with is refused" do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    page = Mirror.get_page!(Demo.restricted_page())
    user = user_fixture()

    socket =
      socket(UserSocket, "user:#{user.id}", %{
        reader_key: "user:#{user.id}",
        user_id: user.id,
        scope: Scope.for_user(user)
      })

    assert {:error, %{reason: "page_not_found"}} =
             subscribe_and_join(socket, PageChannel, Presence.topic(page.confluence_id))
  end

  test "joining an unknown page is rejected" do
    socket = socket(UserSocket, nil, %{})

    assert {:error, %{reason: "page_not_found"}} =
             subscribe_and_join(socket, PageChannel, "page:999999")
  end

  test "a reader with two tabs is one person reading the page" do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    page = Mirror.get_page!(1002)

    tab =
      socket(UserSocket, "user:1", %{
        reader_key: "user:1",
        user_id: 1,
        user_name: "jane",
        scope: anonymous()
      })

    {:ok, _reply, _tab} = subscribe_and_join(tab, PageChannel, Presence.topic(page.confluence_id))
    {:ok, _reply, _tab} = subscribe_and_join(tab, PageChannel, Presence.topic(page.confluence_id))

    # two tabs, one reader
    assert %{"user:1" => %{metas: [_, _]}} =
             Presence.list(Presence.topic(page.confluence_id))

    assert Presence.count(page.confluence_id) == 1
  end

  test "joining the site channel puts the reader online, once per person" do
    tab = socket(UserSocket, "user:1", %{reader_key: "user:1", user_id: 1, user_name: "jane"})

    {:ok, _reply, _tab} = subscribe_and_join(tab, SiteChannel, "site")
    {:ok, _reply, _tab} = subscribe_and_join(tab, SiteChannel, "site")

    assert %{"user:1" => %{metas: [_, _]}} = Presence.list(Presence.site_topic())
    assert Presence.online_count() == 1
  end

  test "two anonymous readers are two people online" do
    {:ok, first} = connect(UserSocket, %{}, connect_info: %{session: %{}})
    {:ok, second} = connect(UserSocket, %{}, connect_info: %{session: %{}})

    {:ok, _reply, _first} = subscribe_and_join(first, SiteChannel, "site")
    {:ok, _reply, _second} = subscribe_and_join(second, SiteChannel, "site")

    assert Presence.online_count() == 2
  end

  # The footer shows a number, so the site topic carries no names: a reader's
  # name is only published on the page they are reading, to its readers.
  test "the site topic never publishes a reader's name" do
    tab = socket(UserSocket, "user:1", %{reader_key: "user:1", user_id: 1, user_name: "jane"})

    {:ok, _reply, _channel} = subscribe_and_join(tab, SiteChannel, "site")

    assert_push "presence_state", state
    refute inspect(state) =~ "jane"
  end

  defp anonymous, do: Scope.for_user(nil)

  defp reader_in_group(group) do
    user = user_fixture()
    {:ok, user} = Accounts.update_groups(user, [group], {:system, "test"})
    user
  end
end
