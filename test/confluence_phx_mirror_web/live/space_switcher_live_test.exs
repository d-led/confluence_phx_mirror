defmodule ConfluencePhxMirrorWeb.SpaceSwitcherLiveTest do
  @moduledoc """
  The top bar's space switcher: a mirror with thousands of spaces cannot ship
  its directory in a menu, so the box asks the server what matches — and only
  what the reader may open is ever offered.

  The menu's open state is the LiveView's, not a `<details>` attribute: a page
  whose content streams re-renders, and an `open` attribute the reader set would
  be taken away from under them.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirrorWeb.SpaceSwitcherLive

  setup do
    demo_snapshot!()
    :ok
  end

  test "the menu starts closed and opens on the button" do
    {:ok, view, _html} = switcher()

    refute has_element?(view, "#space-switcher [role=combobox]")
    assert has_element?(view, "#space-switcher-button[aria-expanded=false]")

    view |> element("#space-switcher-button") |> render_click()

    assert has_element?(view, "#space-switcher-button[aria-expanded=true]")
    assert has_element?(view, "#space-switcher [role=combobox]")
  end

  test "the button closes it again" do
    {:ok, view, _html} = switcher()

    open_menu(view)
    view |> element("#space-switcher-button") |> render_click()

    refute has_element?(view, "#space-switcher [role=combobox]")
  end

  test "it offers the spaces the reader can open, by name and by key" do
    {:ok, view, _html} = switcher()

    open_menu(view)

    assert has_element?(view, "[role=option][data-value='ENG']", "Engineering Handbook")
    assert has_element?(view, "[role=option][data-value='PROD']", "Product Hub")
  end

  test "typing narrows the list to the names and keys that match" do
    {:ok, view, _html} = switcher()

    open_menu(view)
    search(view, "engineering")

    assert has_element?(view, "[role=option][data-value='ENG']")
    refute has_element?(view, "[role=option][data-value='PROD']")

    search(view, "prod")

    assert has_element?(view, "[role=option][data-value='PROD']")
    refute has_element?(view, "[role=option][data-value='ENG']")
  end

  test "a query that matches nothing says so rather than offering something else" do
    {:ok, view, _html} = switcher()

    open_menu(view)
    html = submit(view, "nothing-like-it")

    assert html =~ "No space matches that"
    refute has_element?(view, "[role=option]")
  end

  test "Enter takes the first match, so a typed key goes to that space" do
    {:ok, view, _html} = switcher()

    open_menu(view)
    submit(view, "prod")

    assert_redirect(view, "/spaces/PROD")
  end

  test "a line the reader picks opens that space" do
    {:ok, view, _html} = switcher()

    open_menu(view)
    view |> element("[role=option][data-value='ENG']") |> render_click()

    assert_redirect(view, "/spaces/ENG")
  end

  test "a search re-renders the menu without shutting it" do
    {:ok, view, _html} = switcher()

    open_menu(view)
    search(view, "eng")

    assert has_element?(view, "#space-switcher [role=combobox]")
    assert has_element?(view, "#space-switcher-button[aria-expanded=true]")
  end

  test "somebody else's personal space is never offered" do
    personal = space_fixture(%{key: "~557058ABCDEF", name: "Dana Visitor", type: "personal"})

    {:ok, view, _html} = switcher(%{"user_id" => reader().id})
    open_menu(view)

    refute has_element?(view, "[role=option][data-value='#{personal.key}']")
    refute render(view) =~ "Dana Visitor"
  end

  test "an administrator still sees the personal spaces the mirror holds" do
    personal = space_fixture(%{key: "~557058ABCDEF", name: "Dana Visitor", type: "personal"})

    # The test session is an administrator when it carries no user of its own.
    {:ok, view, _html} = switcher()
    open_menu(view)

    assert has_element?(view, "[role=option][data-value='#{personal.key}']", "Dana Visitor")
  end

  # The switcher offers the reader the spaces they may open, and the session is
  # where that reader comes from: a test that names a user gets them, and one
  # that does not gets the administrator.
  defp switcher(session \\ %{}) do
    session =
      Map.put_new_lazy(session, "user_id", fn ->
        ConfluencePhxMirror.Accounts.ensure_admin!().id
      end)

    live_isolated(build_conn(), SpaceSwitcherLive, session: session)
  end

  defp open_menu(view) do
    view |> element("#space-switcher-button") |> render_click()
  end

  defp search(view, words) do
    view |> element("#space-switcher-select-form") |> render_change(%{"q" => words})
  end

  defp submit(view, words) do
    view |> element("#space-switcher-select-form") |> render_submit(%{"q" => words})
  end

  defp reader, do: user_fixture(%{email: "someone@example.com"})
end
