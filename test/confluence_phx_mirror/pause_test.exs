defmodule ConfluencePhxMirror.PauseTest do
  @moduledoc """
  "Pause Confluence calls" has to mean what it says: no run starts, no queued job
  runs, no space listing is fetched — and the screens that would otherwise say
  "sync now" say why they cannot instead.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.{Repo, Settings, SpaceDirectory}
  alias ConfluencePhxMirror.Sync

  alias ConfluencePhxMirror.Sync.{
    PageWorker,
    SnapshotWorker,
    SpaceWorker,
    SweepWorker,
    SyncRun
  }

  alias ConfluencePhxMirror.TestConfig

  setup do
    Settings.reload()

    on_exit(fn ->
      # The cache outlives the sandbox transaction that held the row.
      Settings.forget()
      Settings.reload()
    end)

    :ok
  end

  describe "a paused mirror" do
    setup do
      {:ok, _applied} = Settings.update(%{"sync.paused" => true}, {:system, "test"})
      :ok
    end

    test "starts no run, and records none" do
      before = Repo.aggregate(SyncRun, :count)

      assert {:error, :paused} = Sync.run(:incremental)
      assert Repo.aggregate(SyncRun, :count) == before
    end

    test "makes a periodic job wait instead of failing it" do
      assert {:snooze, 300} = perform_job(SnapshotWorker, %{})
    end

    test "lets a page that already waits absorb the next request for it" do
      assert {:ok, waiting} = Sync.enqueue(PageWorker, %{"confluence_id" => 42})
      age_past_the_uniqueness_window(waiting)

      assert {:ok, %{id: id, conflict?: true}} =
               Sync.enqueue(PageWorker, %{"confluence_id" => 42})

      assert id == waiting.id
      assert [%{id: ^id}] = all_enqueued(worker: PageWorker)
    end

    test "starts no sweep, so not one space job is queued behind it" do
      assert {:snooze, 300} = perform_job(SweepWorker, %{})
      assert all_enqueued(worker: SpaceWorker) == []
    end

    test "asks the site for no space listing" do
      assert {:error, :paused} = SpaceDirectory.available()
      assert {:error, :paused} = SpaceDirectory.refresh()
    end

    test "says so on the overview, with the way out", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin")

      assert has_element?(view, "#sync-paused")
      assert view |> element("#sync-paused") |> render() =~ "Resume Confluence calls"
    end

    test "the overview's button resumes, and pauses again", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin")

      view |> element("#sync-pause-toggle") |> render_click()

      refute Settings.sync_paused?()
      refute has_element?(view, "#sync-paused")

      view |> element("#sync-pause-toggle") |> render_click()

      assert Settings.sync_paused?()
      assert has_element?(view, "#sync-paused")
    end

    test "says so on the identities screen, and offers no sync", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/identities")

      assert has_element?(view, "#sync-identities[disabled]")
      assert has_element?(view, "#identities-paused")
    end

    test "says so in the footer of a reader page", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200) =~ "updates paused"
    end
  end

  test "resuming lets the next run start again", %{conn: _conn} do
    {:ok, _applied} = Settings.update(%{"sync.paused" => true}, {:system, "test"})
    assert {:error, :paused} = Sync.run(:incremental)

    {:ok, _applied} = Settings.update(%{"sync.paused" => false}, {:system, "test"})

    assert {:ok, %{status: "succeeded"}} = Sync.run(:incremental)
  end

  test "a page asked for twice, a minute apart, is two jobs while the mirror runs" do
    assert {:ok, first} = Sync.enqueue(PageWorker, %{"confluence_id" => 7})
    age_past_the_uniqueness_window(first)

    assert {:ok, second} = Sync.enqueue(PageWorker, %{"confluence_id" => 7})

    refute second.id == first.id
    assert length(all_enqueued(worker: PageWorker)) == 2
  end

  # A job's uniqueness period is counted from its `inserted_at`, and a test will
  # not sit through the minute: it moves the queued job back instead, which is
  # the same queue an event a minute later would have met.
  defp age_past_the_uniqueness_window(%Oban.Job{id: id}) do
    job = Repo.get!(Oban.Job, id)

    job
    |> Ecto.Changeset.change(inserted_at: DateTime.add(job.inserted_at, -60, :second))
    |> Repo.update!()
  end

  defp admin_user do
    TestConfig.put(:admins, ["ops-pause@example.com"])

    user_fixture(%{email: "ops-pause@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
