defmodule ConfluencePhxMirrorWeb.Admin.TrashLiveTest do
  @moduledoc """
  The trash is the only place content is deleted for good, so it has to say what
  is in it, what goes with what, and ask twice before emptying.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.{Mirror, Repo, Trash}
  alias ConfluencePhxMirror.Mirror.{Page, Space}
  alias ConfluencePhxMirror.Trash.PurgeWorker

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops-trash@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "an empty trash says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/trash")

    assert html =~ "The trash is empty"
  end

  test "a trashed space is listed with its pages and purged on request", %{conn: conn} do
    space = space_fixture(%{key: "GONE", name: "Gone Space"})
    page = page_fixture(space)

    assert Mirror.trash_space(space) == 1

    {:ok, view, html} = live(conn, ~p"/admin/trash")

    assert html =~ "GONE"
    assert html =~ "Gone Space"

    # When it was trashed goes to the browser as an instant, for the reader's
    # clock; printing Time.datetime/1 here would leave a UTC string on screen.
    assert has_element?(view, "#space-GONE time[data-local-time]")

    html = view |> element("#space-GONE button", "Delete for good") |> render_click()

    assert html =~ "GONE purged with 1 pages"
    assert Repo.get(Space, space.id) == nil
    assert Repo.get(Page, page.id) == nil
  end

  test "a trashed page is listed and purged on request", %{conn: conn} do
    space = space_fixture(%{key: "LIVE"})
    page = page_fixture(space, %{title: "Retired runbook"})

    Mirror.mark_missing_deleted(space, [])

    {:ok, view, html} = live(conn, ~p"/admin/trash")

    assert html =~ "Retired runbook"

    html = view |> element("#page-#{page.id} button", "Delete for good") |> render_click()

    assert html =~ "Retired runbook"
    assert Repo.get(Page, page.id) == nil
  end

  test "emptying the trash asks for a second click", %{conn: conn} do
    space = space_fixture(%{key: "BULK"})
    page_fixture(space)
    Mirror.trash_space(space)

    {:ok, view, html} = live(conn, ~p"/admin/trash")

    assert has_element?(view, "#space-BULK")
    refute has_element?(view, "#confirm-empty")
    assert html =~ "BULK"

    html = view |> element("#empty-trash") |> render_click()
    assert html =~ "1 spaces and 0 pages for good"

    html = view |> element("#confirm-empty") |> render_click()

    assert html =~ "Purged 1 spaces and 0 pages for good."
    assert Trash.spaces() == []
  end

  test "refuses to purge a space that came back", %{conn: conn} do
    space = space_fixture(%{key: "BACK"})
    Mirror.trash_space(space)

    {:ok, view, _html} = live(conn, ~p"/admin/trash")

    # A sync can bring the space back between the page loading and the click.
    Mirror.upsert_space(%{key: "BACK", name: "Back again"})

    html = view |> element("#space-BACK button", "Delete for good") |> render_click()

    assert html =~ "BACK is live again"
    assert Repo.get(Space, space.id)
  end

  describe "deleting it later" do
    test "says what a holding period would delete, and deletes only that", %{conn: conn} do
      space = space_fixture(%{key: "AGED"})
      old = page_fixture(space, %{title: "Long gone"})
      young = page_fixture(space, %{title: "Just gone"})
      {:ok, old} = Trash.trash_page({:system, "test"}, old, space)
      {:ok, _young} = Trash.trash_page({:system, "test"}, young, space)
      age!(old, 40)

      {:ok, view, html} = live(conn, ~p"/admin/trash")

      assert html =~ "Delete it later"
      assert has_element?(view, "#retention-count", "0 spaces and 1 pages")

      view |> form("form[phx-change=retention_days]", %{"days" => "30"}) |> render_change()
      html = view |> element("#purge-due") |> render_click()

      assert html =~ "0 spaces and 1 pages for good"

      html = view |> element("#confirm-purge-due") |> render_click()

      assert html =~ "Deleting 0 spaces and 1 pages in the background"
      assert_enqueued(worker: PurgeWorker)

      # Queued, not done: the job removes it when it runs.
      assert Repo.get(Page, old.id)
      assert length(Trash.pages()) == 2
    end

    test "offers nothing to delete while the trash is younger than the holding period", %{
      conn: conn
    } do
      space = space_fixture(%{key: "FRESH"})
      page = page_fixture(space)
      {:ok, _} = Trash.trash_page({:system, "test"}, page, space)

      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "#purge-due[disabled]")
    end
  end

  defp age!(%_{} = row, days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    row |> Ecto.Changeset.change(deleted_at: at) |> Repo.update!()
  end
end
