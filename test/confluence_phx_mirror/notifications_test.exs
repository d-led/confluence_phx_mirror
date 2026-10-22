defmodule ConfluencePhxMirror.NotificationsTest do
  @moduledoc """
  A subscription records what a reader asked for; whether a message may be sent
  is decided when the page changes, from the permissions as they stand then.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Notifications

  setup do
    demo_snapshot!()
    :ok
  end

  test "a subscriber who may not read the page is not told about it" do
    {:ok, page} = Mirror.find_page(Demo.restricted_page())

    subscriber = user_fixture()
    {:ok, _subscription} = Notifications.subscribe(subscriber, "page", page.id)

    assert Notifications.page_changed(page, :updated) == []
    assert Notifications.recent() == []
  end

  test "a subscriber who may read the page is told" do
    {:ok, page} = Mirror.find_page(Demo.open_page())

    subscriber = user_fixture()
    {:ok, _subscription} = Notifications.subscribe(subscriber, "page", page.id)

    assert [_notification] = Notifications.page_changed(page, :updated)
    assert [%{subject: subject}] = Notifications.recent()
    assert subject =~ page.title
  end
end
