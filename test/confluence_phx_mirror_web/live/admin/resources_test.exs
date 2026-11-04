defmodule ConfluencePhxMirrorWeb.Admin.ResourcesTest do
  @moduledoc """
  The overview answers the question an operator asks when a sync dies or a disk
  fills: how big is this thing, and how much room is left beside it.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ops = user_fixture(%{role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the overview shows the data mount, the room left and the memory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    mount = view |> render() |> text_of("#resources-blob-mount")

    assert mount =~ "Data mount"
    assert mount =~ "files, measured"
    assert mount =~ "free of"

    memory = view |> render() |> text_of("#resources-memory")

    assert memory =~ "Memory"
    assert memory =~ "available of"
    assert memory =~ "this VM:"
  end

  # Per-table sizes are Postgres's: it reports what each relation and the
  # tablespace use, and never how much room the volume has left. The tool's
  # SQLite answers with the file and says the rest is not reported by its store,
  # so this card's Postgres wording is the deployment's alone.
  @tag :postgres_only
  test "the database card says what Postgres reports", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    database = view |> render() |> text_of("#resources-database")

    assert database =~ "Postgres"
    assert database =~ "biggest:"
    assert database =~ "in the default tablespace (WAL"
  end

  test "each bar says how much of its device this mirror accounts for", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    html = render(view)

    assert bar_label(html, "#resources-blob-mount") =~ "of it ours,"
    assert bar_label(html, "#resources-memory") =~ "of it ours,"
    # Postgres reports what it uses and never how big its volume is, so this one
    # waits for CM_DATABASE_CAPACITY_GB rather than guessing a share of nothing.
    assert bar_label(html, "#resources-database") == nil
  end

  defp bar_label(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#{selector} [role="img"]))
    |> LazyHTML.attribute("aria-label")
    |> List.first()
  end

  defp text_of(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end
end
