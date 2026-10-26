defmodule ConfluencePhxMirrorWeb.Live.SearchControlsTest do
  @moduledoc """
  The filter controls on the search page: what clicking a pill or typing a label
  does to the address, because the address is what a reader can share.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  @moduletag :empty_mirror

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  setup do
    %{space: space_fixture(%{name: "Engineering Handbook"})}
  end

  # A reader opens a filter before picking from it.
  defp open_menu(view, id) do
    view |> element("#{id} > button") |> render_click()
    view
  end

  test "naming a space narrows the search, and naming it again widens it", %{
    conn: conn,
    space: space
  } do
    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> open_menu("#space-filter")
    |> element("button[phx-click='set_space'][phx-value-space='#{space.key}']")
    |> render_click()

    assert_patch(view, ~p"/search?space=#{space.key}")
    assert has_element?(view, "a", "Space: #{space.key}")

    view
    |> open_menu("#space-filter")
    |> element("button[phx-click='set_space'][phx-value-space='#{space.key}']")
    |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "toggling a content type adds it to the search and toggling it back removes it", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> open_menu("#type-filter")

    view
    |> element("button[phx-click='toggle_type'][phx-value-type='page']")
    |> render_click()

    assert_patch(view, ~p"/search?types=page")
    assert has_element?(view, "a", "Type: pages")

    # The type menu stays open: a reader can pick several kinds in one go.
    view
    |> element("button[phx-click='toggle_type'][phx-value-type='page']")
    |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "picking a time window replaces the previous one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?updated=7d")

    view
    |> open_menu("#updated-filter")
    |> element("button[phx-click='set_updated'][phx-value-updated='30d']")
    |> render_click()

    assert_patch(view, ~p"/search?updated=30d")

    view
    |> open_menu("#updated-filter")
    |> element("button[phx-click='set_updated'][phx-value-updated='30d']")
    |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "picking a person narrows the search by author, and picking them again widens it", %{
    conn: conn,
    space: space
  } do
    page_fixture(space, %{author_name: "Jane Doe"})
    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> open_menu("#creator-filter")
    |> element("button[phx-click='set_creator'][phx-value-creator='Jane Doe']")
    |> render_click()

    assert_patch(view, ~p"/search?creator=Jane+Doe")
    assert has_element?(view, "a", "By: Jane Doe")

    view
    |> open_menu("#creator-filter")
    |> element("button[phx-click='set_creator'][phx-value-creator='Jane Doe']")
    |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "typing in the author box narrows who is offered", %{conn: conn, space: space} do
    page_fixture(space, %{author_name: "Jane Doe"})
    page_fixture(space, %{author_name: "Sam Smith"})
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> open_menu("#creator-filter")
    assert has_element?(view, "#people-options", "Sam Smith")

    view |> element("#people-form") |> render_change(%{"people" => "jan"})

    assert has_element?(view, "#people-options", "Jane Doe")
    refute has_element?(view, "#people-options", "Sam Smith")
  end

  test "the sort is a filter too: a chip says which one, and Best match takes it away", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> element("#sort-form") |> render_change(%{"sort" => "newest"})

    assert_patch(view, ~p"/search?sort=newest")
    assert has_element?(view, "a", "Sort: newest first")

    view |> element("#sort-form") |> render_change(%{"sort" => ""})

    assert_patch(view, ~p"/search")
    refute has_element?(view, "a", "Sort: newest first")
  end

  test "a phone folds the filter row behind one button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#filters-toggle[aria-expanded=false]")

    view |> element("#filters-toggle") |> render_click()

    assert has_element?(view, "#filters-toggle[aria-expanded=true]")
  end

  test "typing a label and submitting it filters by it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> open_menu("#labels-filter")
    view |> element("#label-form") |> render_submit(%{"label" => "Release Notes"})

    assert_patch(view, ~p"/search?labels=release-notes")
    assert has_element?(view, "#labels-filter", "Label: release-notes")

    view |> element("#labels-filter button[phx-value-label='']") |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "the suggestion field keeps what the reader is typing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> open_menu("#labels-filter")
    view |> element("#label-form") |> render_change(%{"label" => "rel"})

    assert has_element?(view, "input[name='label'][value='rel']")
  end

  test "a label that is only whitespace filters by nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> open_menu("#labels-filter")
    view |> element("#label-form") |> render_submit(%{"label" => "   "})

    refute has_element?(view, "#labels-filter button[phx-value-label='']")
  end

  test "each finder is a combobox a keyboard can walk, marking what it applied", %{
    conn: conn,
    space: space
  } do
    {:ok, view, _html} = live(conn, ~p"/search?space=#{space.key}")
    view |> open_menu("#space-filter")

    # What Enter sends and what the arrows move over: one box wired to one
    # list, one addressable line per space, and a tick on the filter in force.
    assert has_element?(view, "input[name=space][role=combobox][aria-controls=space-options]")
    assert has_element?(view, "ul#space-options[role=listbox]")

    assert has_element?(
             view,
             "#space-options [role=option][data-value='#{space.key}'][aria-selected=true]"
           )

    assert has_element?(view, "#space-options [role=option][phx-value-space='']")
  end

  test "Escape closes whichever filter is open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> open_menu("#labels-filter")
    assert has_element?(view, "#labels-filter-panel")

    view |> element("#labels-filter") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#labels-filter-panel")
  end

  test "the page names itself for screen readers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "h1", "Search the mirror")
  end

  test "typing a question searches for it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> element("#search-form") |> render_change(%{"search" => %{"q" => "rate limit"}})

    assert_patch(view, ~p"/search?q=rate+limit")
    assert has_element?(view, "a", "rate limit")
  end

  test "clearing the search forgets every filter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=rate&types=page&updated=7d")

    view |> element("button[aria-label='Clear search']") |> render_click()

    assert_patch(view, ~p"/search")
  end
end
