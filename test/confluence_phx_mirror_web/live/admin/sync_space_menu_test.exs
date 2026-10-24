defmodule ConfluencePhxMirrorWeb.Admin.SyncSpaceMenuTest do
  @moduledoc """
  "Sync one space" is a find box, not a list of everything: it opens with the
  cursor already in the input, and typing narrows the list in the database.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Repo

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})
    space_fixture(%{key: "MFS", name: "My first space"})
    space_fixture(%{key: "ENG", name: "Engineering"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "it opens with a find box, and typing narrows the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    refute has_element?(view, "#sync-space-panel")
    view |> element("#sync-space-menu button[phx-value-menu=sync-space]") |> render_click()

    assert has_element?(view, "#sync-space-panel input[name=space]")
    assert has_element?(view, "#sync-space-panel", "Engineering")

    view |> element("#sync-space-form") |> render_change(%{"space" => "eng"})

    assert has_element?(view, "#sync-space-panel", "Engineering")
    refute has_element?(view, "#sync-space-panel", "My first space")
  end

  test "a query that matches nothing says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("#sync-space-menu button[phx-value-menu=sync-space]") |> render_click()
    view |> element("#sync-space-form") |> render_change(%{"space" => "zzz"})

    assert has_element?(view, "#sync-space-panel", "No space matches")
  end

  test "picking a space queues it and closes the menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("#sync-space-menu button[phx-value-menu=sync-space]") |> render_click()
    view |> element("#sync-space-panel button[phx-value-key=ENG]") |> render_click()

    refute has_element?(view, "#sync-space-panel")
    assert queued_space_keys() == ["ENG"]
  end

  test "the list is a combobox a keyboard can walk", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("#sync-space-menu button[phx-value-menu=sync-space]") |> render_click()

    # What the arrow keys need to find: one box wired to one list, and one
    # addressable line per space that Enter can take.
    assert has_element?(view, "input[role=combobox][aria-controls=sync-space-options]")
    assert has_element?(view, "ul#sync-space-options[role=listbox]")
    assert has_element?(view, "#sync-space-option-ENG[role=option][phx-value-key=ENG]")
    assert has_element?(view, "#sync-space-option-MFS[role=option][phx-value-key=MFS]")
  end

  defp queued_space_keys do
    Repo.all(from j in Oban.Job, where: j.queue == "sync", select: j.args["space_key"])
  end
end
