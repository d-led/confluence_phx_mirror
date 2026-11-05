defmodule ConfluencePhxMirrorWeb.WatchLiveTest do
  @moduledoc """
  The Watch control commits where the reader is standing.

  Watching a page or a space used to be a form posting to `/subscriptions` and a
  redirect to the referer: a reload, a lost scroll position, a dropped dialog,
  and a flash standing in for the button the reader pressed. The control is now
  an island `live_render/3` puts into the page's rail and into the space screen,
  so the press is answered by the process that owns the button.

  Three things are asked of it. That the write happened — read back from the
  database, not from the socket's opinion. That the label follows the write in
  the same live view, which is what "it did not navigate" looks like from here.
  And that a target the reader may not open is not offered at all.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirrorWeb.WatchLive

  @page_path "/spaces/ENG/pages/1002/Architecture+Overview"
  @space_path "/spaces/ENG"

  setup do
    demo_snapshot!()

    {:ok, page} = Mirror.find_page(Demo.open_page_number())
    {:ok, space} = Mirror.find_space("ENG")

    %{page: page, space: space, reader: user_fixture()}
  end

  describe "watching from the page" do
    test "the press commits the subscription and turns the button, in place",
         %{conn: conn, page: page, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_page: page.id)

      assert has_element?(view, "#watch-page", "Watch this page")

      view |> element("#watch-page") |> render_click()

      assert Notifications.subscribed?(reader, "page", page.id)
      assert has_element?(view, "#watch-page", "Stop watching")
      refute has_element?(view, "#watch-page", "Watch this page")
    end

    test "the act is audited, as it was when a form did it",
         %{conn: conn, page: page, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_page: page.id)

      view |> element("#watch-page") |> render_click()

      assert [event] =
               Audit.search(action: "subscription.created")
               |> Enum.filter(&(&1.entity_id == to_string(page.id)))

      assert event.entity_type == "page"
      assert event.metadata["user"] == reader.email
    end

    test "pressing stop again removes the subscription and turns the button back",
         %{conn: conn, page: page, reader: reader} do
      {:ok, _subscription} = Notifications.subscribe(reader, "page", page.id)
      {:ok, view, _html} = watch(conn, reader, watch_page: page.id)

      assert has_element?(view, "#watch-page", "Stop watching")

      view |> element("#watch-page") |> render_click()

      refute Notifications.subscribed?(reader, "page", page.id)
      assert has_element?(view, "#watch-page", "Watch this page")
      assert Audit.search(action: "subscription.deleted") != []
    end
  end

  describe "watching from the space screen" do
    test "the press commits the subscription and turns the button, in place",
         %{conn: conn, space: space, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_space: space, watch_space_key: space.key)

      assert has_element?(view, "#watch-space", "Watch all of ENG")

      view |> element("#watch-space") |> render_click()

      assert Notifications.subscribed?(reader, "space", space.id)
      assert has_element?(view, "#watch-space", "Stop watching ENG")
      assert has_element?(view, "#watch-space-note", "Watching the whole space.")
    end

    test "pressing stop removes it again", %{conn: conn, space: space, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_space: space, watch_space_key: space.key)

      view |> element("#watch-space") |> render_click()
      view |> element("#watch-space") |> render_click()

      refute Notifications.subscribed?(reader, "space", space.id)
      assert has_element?(view, "#watch-space", "Watch all of ENG")
    end
  end

  describe "what the control offers" do
    test "a page the reader may not open is not offered at all",
         %{conn: conn, reader: reader} do
      {:ok, restricted} = Mirror.find_page(Demo.restricted_page_number())

      {:ok, view, _html} = watch(conn, reader, watch_page: restricted.id)

      refute has_element?(view, "#watch-page")
      refute Notifications.subscribed?(reader, "page", restricted.id)
    end

    test "a target it was not given is not offered", %{conn: conn, page: page, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_page: page.id)

      refute has_element?(view, "#watch-space")
    end

    test "a page the mirror does not have is not offered", %{conn: conn, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_page: 999_999)

      refute has_element?(view, "#watch-page")
    end

    test "a reader with no session is told to sign in, and the button stays put",
         %{conn: conn, page: page} do
      {:ok, view, _html} = watch(conn, nil, watch_page: page.id)

      view |> element("#watch-page") |> render_click()

      assert has_element?(view, "#watch-page", "Watch this page")
    end

    test "a press naming something it does not know is refused, and the island stays up",
         %{conn: conn, page: page, reader: reader} do
      {:ok, view, _html} = watch(conn, reader, watch_page: page.id)

      render_click(view, "toggle", %{"target" => "attachment"})

      refute Notifications.subscribed?(reader, "page", page.id)
      assert has_element?(view, "#watch-page", "Watch this page")
    end
  end

  describe "the screens that carry it" do
    test "the page's rail renders the control and no form that navigates", %{conn: conn} do
      html = conn |> log_in_admin() |> get(@page_path) |> html_response(200)

      assert html =~ ~s(id="watch-page")
      refute html =~ ~s(action="/subscriptions")
    end

    test "the space screen offers watching the space", %{conn: conn} do
      html = conn |> log_in_admin() |> get(@space_path) |> html_response(200)

      assert html =~ ~s(id="watch-space")
      refute html =~ ~s(action="/subscriptions")
    end
  end

  defp watch(conn, reader, session) do
    session =
      session
      |> Map.new(fn
        {:watch_page, id} -> {"watch_page", id}
        {:watch_space, %{id: id}} -> {"watch_space", id}
        {:watch_space_key, key} -> {"watch_space_key", key}
      end)
      |> maybe_signed_in(reader)

    live_isolated(conn, WatchLive, session: session)
  end

  defp maybe_signed_in(session, %{id: id}), do: Map.put(session, "user_id", id)
  defp maybe_signed_in(session, nil), do: session
end
