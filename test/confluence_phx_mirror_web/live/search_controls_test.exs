defmodule ConfluencePhxMirrorWeb.Live.SearchControlsTest do
  @moduledoc """
  The filter controls on the search page: what clicking a pill or typing a label
  does to the address, because the address is what a reader can share.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  setup do
    %{space: space_fixture(%{name: "Engineering Handbook"})}
  end

  test "naming a space narrows the search, and naming it again widens it", %{
    conn: conn,
    space: space
  } do
    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> element("button[phx-click='set_space'][phx-value-value='#{space.key}']")
    |> render_click()

    assert_patch(view, ~p"/search?space=#{space.key}")
    assert has_element?(view, "a", "Space: #{space.key}")

    view
    |> element("button[phx-click='set_space'][phx-value-value='#{space.key}']")
    |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "toggling a content type adds it to the search and toggling it back removes it", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> element("button[phx-click='toggle_type'][phx-value-value='page']") |> render_click()
    assert_patch(view, ~p"/search?types=page")
    assert has_element?(view, "a", "Type: pages")

    view |> element("button[phx-click='toggle_type'][phx-value-value='page']") |> render_click()
    assert_patch(view, ~p"/search")
  end

  test "picking a time window replaces the previous one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?updated=7d")

    view |> element("button[phx-click='set_updated'][phx-value-value='30d']") |> render_click()
    assert_patch(view, ~p"/search?updated=30d")

    view |> element("button[phx-click='set_updated'][phx-value-value='30d']") |> render_click()
    assert_patch(view, ~p"/search")
  end

  test "typing a label and submitting it filters by it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> element("#label-form") |> render_submit(%{"label" => "Release Notes"})

    assert_patch(view, ~p"/search?labels=release-notes")
    assert has_element?(view, "#labels-filter", "Label: release-notes")

    view |> element("#labels-filter button[phx-click='clear_labels']") |> render_click()

    assert_patch(view, ~p"/search")
  end

  test "the suggestion field keeps what the reader is typing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    view |> element("#label-form") |> render_change(%{"label" => "rel"})

    assert has_element?(view, "input[name='label'][value='rel']")
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
