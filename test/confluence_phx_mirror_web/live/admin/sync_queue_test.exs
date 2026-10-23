defmodule ConfluencePhxMirrorWeb.Admin.SyncQueueTest do
  @moduledoc """
  The syncs still waiting are lines in the same list as the runs that already
  happened, and each one can be dropped before anything picks it up.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SpaceWorker

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "a waiting sync sits in the run list with a button that drops it", %{conn: conn} do
    job = queued_space_sync("MFS")

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#sync-runs #cancel-queued-#{job.id}")
    assert render(view) =~ "space MFS"
  end

  test "dropping a waiting sync cancels the job and takes its line away", %{conn: conn} do
    job = queued_space_sync("MFS")
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#cancel-queued-#{job.id}") |> render_click()

    refute has_element?(view, "#cancel-queued-#{job.id}")
    assert state_of(job) == "cancelled"
    assert render(view) =~ "that sync will not run"
  end

  test "a sync that already started is a run, not a queue line", %{conn: conn} do
    job = queued_space_sync("MFS")
    set_state(job, "executing")

    {:ok, view, _html} = live(conn, ~p"/admin")

    refute has_element?(view, "#cancel-queued-#{job.id}")
    assert state_of(job) == "executing"
  end

  test "a run in flight says what it is doing and how far it has got", %{conn: conn} do
    # The dashboard abandons a "running" run whose node is gone, so this one has
    # to look alive: the lease is the mirror's own way of saying so.
    hold_gate()
    start_running_run(%{"pages" => 120, "changed" => 120, "phase" => "details"})

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#sync-progress")
    assert view |> element("#sync-phase") |> render() =~ "comments, files and restrictions"
    assert render(view) =~ "120"
  end

  defp hold_gate do
    Repo.update_all(from(g in "sync_gate"),
      set: [
        owner: "a test holding the gate",
        expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
      ]
    )
  end

  defp start_running_run(stats) do
    {:ok, run} =
      %ConfluencePhxMirror.Sync.SyncRun{}
      |> ConfluencePhxMirror.Sync.SyncRun.changeset(%{
        source: "confluence-demo",
        mode: "snapshot",
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second),
        stats: stats
      })
      |> Repo.insert()

    run
  end

  defp queued_space_sync(key) do
    {:ok, job} = SpaceWorker.new(%{"space_key" => key, "trigger" => "a test"}) |> Oban.insert()
    job
  end

  defp set_state(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end

  defp state_of(job), do: Repo.get!(Oban.Job, job.id).state
end
