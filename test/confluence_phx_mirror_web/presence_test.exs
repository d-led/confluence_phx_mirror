defmodule ConfluencePhxMirrorWeb.PresenceTest do
  @moduledoc """
  Who is reading what: a page's rail names the people on that page, the footer
  counts the people with the mirror open, and both are the page's own LiveViews
  — the pages themselves are controller responses with no process to track.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirrorWeb.PagePresenceLive
  alias ConfluencePhxMirrorWeb.Presence
  alias ConfluencePhxMirrorWeb.SitePresenceLive

  setup do
    # A mirror can be set up to sign a stranger straight in (development does,
    # and so does this suite); these tests are about who is reading, so a
    # session with no user in it has to stay anonymous.
    auto_admin = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, auto_admin) end)

    {:ok, _run} = ConfluencePhxMirror.Sync.run(:snapshot)
    :ok
  end

  describe "a page's rail" do
    test "says who is reading the page", %{conn: conn} do
      {:ok, _view, html} = reading_page(conn, user_fixture(%{display_name: "Jane"}))

      assert readers(html) == ["Jane"]
    end

    test "shows the readers as they arrive", %{conn: conn} do
      {:ok, jane_view, _html} = reading_page(conn, user_fixture(%{display_name: "Jane"}))
      {:ok, _sam_view, _html} = reading_page(conn, user_fixture(%{display_name: "Sam"}))

      assert readers(render(jane_view)) == ["Jane", "Sam"]
    end

    test "counts two tabs of one account as one reader", %{conn: conn} do
      jane = user_fixture(%{display_name: "Jane"})

      {:ok, first_tab, _html} = reading_page(conn, jane)
      {:ok, _second_tab, _html} = reading_page(conn, jane)

      assert readers(render(first_tab)) == ["Jane"]
    end

    test "counts two strangers as two readers", %{conn: conn} do
      {:ok, first, _html} = reading_page(conn, nil)
      {:ok, _second, _html} = reading_page(conn, nil)

      assert readers(render(first)) == ["Anonymous reader", "Anonymous reader"]
    end

    test "a page the reader may not open lists nobody", %{conn: conn} do
      {:ok, _view, html} = reading_page(conn, nil, page: Demo.restricted_page())

      assert readers(html) == []
    end

    test "a page shared with the reader's group lists them", %{conn: conn} do
      user = in_group(Demo.page_readers())

      {:ok, _view, html} = reading_page(conn, user, page: Demo.restricted_page())

      assert length(readers(html)) == 1
    end
  end

  describe "the footer" do
    test "counts two tabs of one account as one person online", %{conn: conn} do
      jane = user_fixture()

      {:ok, _first_tab, _html} = online(conn, jane)
      {:ok, _second_tab, _html} = online(conn, jane)

      key = Presence.site_key(Presence.key(jane))
      assert %{^key => %{metas: [_, _]}} = Presence.list(Presence.site_topic())
    end

    test "publishes neither a name nor an account id", %{conn: conn} do
      jane = user_fixture(%{display_name: "Jane"})

      {:ok, _view, _html} = online(conn, jane)

      state = Presence.list(Presence.site_topic())
      key = Presence.site_key(Presence.key(jane))

      assert %{^key => _} = state
      refute key =~ "user:"
      refute inspect(state) =~ "Jane"
    end
  end

  defp reading_page(conn, user, opts \\ []) do
    page = Keyword.get(opts, :page, Demo.open_page_number())

    live_isolated(conn, PagePresenceLive,
      session: %{"presence_page" => page} |> signed_in_as(user)
    )
  end

  defp online(conn, user),
    do: live_isolated(conn, SitePresenceLive, session: signed_in_as(%{}, user))

  defp signed_in_as(session, nil), do: session
  defp signed_in_as(session, %{id: id}), do: Map.put(session, "user_id", id)

  defp readers(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#page-presence-readers li")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp in_group(group) do
    user = user_fixture()
    {:ok, user} = Accounts.update_groups(user, [group], {:system, "test"})
    user
  end
end
