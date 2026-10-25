defmodule ConfluencePhxMirrorWeb.Admin.ResourcesTest do
  @moduledoc """
  The overview answers the question an operator asks when a sync dies or a disk
  fills: how big is this thing, and how much room is left beside it.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the overview shows the data mount, the room left and the database", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    mount = view |> render() |> text_of("#resources-blob-mount")

    assert mount =~ "Data mount"
    assert mount =~ "files, measured"
    assert mount =~ "free of"

    database = view |> render() |> text_of("#resources-database")

    assert database =~ "Postgres"
    assert database =~ "biggest:"
    # Postgres reports what it uses, never what is left, so without a configured
    # volume size the card says what it does know: the tablespace footprint.
    assert database =~ "in the default tablespace (WAL"

    memory = view |> render() |> text_of("#resources-memory")

    assert memory =~ "Memory"
    assert memory =~ "available of"
    assert memory =~ "this VM:"
  end

  defp text_of(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end
end
