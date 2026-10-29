defmodule ConfluencePhxMirrorWeb.PresenceTest do
  @moduledoc """
  The rules of presence that no page can show you.

  What a reader sees is tested through the pages themselves
  (`ReaderPagePresenceTest` for a page's rail, `SitePresenceTest` for the
  footer). What is left belongs to the module: one account is one person, a
  stranger is their own connection, the site topic publishes no names, and a
  page the reader may not open lists nobody — the last one has to be asked of
  the LiveView directly, because the page itself answers 404 before any widget
  is rendered.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirrorWeb.PagePresenceLive
  alias ConfluencePhxMirrorWeb.Presence
  alias ConfluencePhxMirrorWeb.SitePresenceLive

  setup do
    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    :ok
  end

  test "one account is one reader, and each stranger is their own" do
    jane = user_fixture()

    assert Presence.key(jane) == Presence.key(jane)
    refute Presence.key(nil) == Presence.key(nil)
  end

  test "the site topic keeps a reader's name and account to themselves", %{conn: conn} do
    jane = user_fixture(%{display_name: "Jane"})

    {:ok, _view, _html} = live_isolated(conn, SitePresenceLive, session: %{"user_id" => jane.id})

    state = Presence.list(Presence.site_topic())
    key = Presence.site_key(Presence.key(jane))

    assert %{^key => _} = state
    refute key =~ "user:"
    refute inspect(state) =~ "Jane"
  end

  test "a page the reader may not open lists nobody", %{conn: conn} do
    stranger = user_fixture()

    {:ok, view, _html} =
      live_isolated(conn, PagePresenceLive,
        session: %{"presence_page" => Demo.restricted_page(), "user_id" => stranger.id}
      )

    assert has_element?(view, "#page-presence-count", "0")
    refute has_element?(view, "#page-presence-readers li")
  end
end
