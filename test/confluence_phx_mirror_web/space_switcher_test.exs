defmodule ConfluencePhxMirrorWeb.SpaceSwitcherTest do
  @moduledoc """
  The shell's space names, and the box the top bar offers instead of a list.

  A space is known by its name ("LOAD01 Test Space 2") and told apart by its key
  ("LOAD012"). A personal space has nothing to tell apart — its key is an
  account id and its name is the owner — so the shell leaves the id out rather
  than showing a truncated hash nobody reads.

  The top bar is not a list of spaces any more, because there may be thousands
  of them: it is a find box the server answers (see `SpaceSwitcherLiveTest`).
  What is pinned here is that the box is there, and the sidebar's list of
  mirrored spaces still names each space the same way.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  test "a space is listed with its name and the key that tells it apart", %{conn: conn} do
    space_fixture(%{key: "LOAD012", name: "LOAD01 Test Space 2"})

    assert sidebar(conn) =~ "LOAD01 Test Space 2"
    assert sidebar(conn) =~ "LOAD012"
  end

  test "a personal space is listed by its owner's name alone", %{conn: conn} do
    space_fixture(%{key: "~712020f4c1", name: "Ann Example", type: "personal"})

    # Personal spaces are the owner's (and an administrator's) to see.
    sidebar = sidebar(log_in_admin(conn))

    assert sidebar =~ "Ann Example"
    refute sidebar =~ "712020f4c1"
  end

  test "the top bar offers a switcher rather than the whole directory", %{conn: conn} do
    document = conn |> get(~p"/spaces") |> html_response(200) |> LazyHTML.from_document()

    buttons = LazyHTML.query(document, "#space-switcher #space-switcher-button")

    assert Enum.count(buttons) == 1
  end

  defp sidebar(conn) do
    conn
    |> get(~p"/spaces")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("#mirror-sidebar ul.menu")
    |> LazyHTML.text()
  end
end
