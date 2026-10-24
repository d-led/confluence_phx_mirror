defmodule ConfluencePhxMirrorWeb.SpaceSwitcherTest do
  @moduledoc """
  The shell's space switcher: the spaces a reader can open, each named the way
  the reader knows it.

  A space is known by its name ("LOAD01 Test Space 2") and told apart by its key
  ("LOAD012"). A personal space has no such thing — its key is an account id and
  its name is the owner — so the switcher leaves the id out rather than showing
  a truncated hash nobody reads.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  test "a space is listed with its name and the key that tells it apart", %{conn: conn} do
    space_fixture(%{key: "LOAD012", name: "LOAD01 Test Space 2"})

    assert switcher(conn) =~ "LOAD01 Test Space 2"
    assert switcher(conn) =~ "LOAD012"
  end

  test "a personal space is listed by its owner's name alone", %{conn: conn} do
    space_fixture(%{key: "~712020f4c1", name: "Ann Example", type: "personal"})

    switcher = switcher(conn)

    assert switcher =~ "Ann Example"
    refute switcher =~ "712020f4c1"
  end

  defp switcher(conn) do
    conn
    |> get(~p"/spaces")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("details[name=topbar-menu] ul.menu")
    |> LazyHTML.text()
  end
end
