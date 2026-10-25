defmodule ConfluencePhxMirrorWeb.Admin.JobsLiveTest do
  @moduledoc """
  Oban's own rows on a page: what is waiting, what is running, and what a
  restart left behind — each with the one action that ends it.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SpaceWorker
  alias ConfluencePhxMirror.Sync.SyncRun

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "a job left executing by a dead node can be stopped from the page", %{conn: conn} do
    job = sync_job("MFS") |> with_state("executing")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#stop-job-#{job.id}")

    view |> element("#stop-job-#{job.id}") |> render_click()

    assert state_of(job) == "cancelled"
    assert render(view) =~ "Cancelled job ##{job.id}"
    refute has_element?(view, "#stop-job-#{job.id}")
  end

  test "stopping a job is recorded with who did it", %{conn: conn} do
    job = sync_job("MFS") |> with_state("executing")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    view |> element("#stop-job-#{job.id}") |> render_click()

    entry =
      from(e in Event, where: e.action == "job.cancelled", order_by: [desc: e.id])
      |> Repo.one!()

    assert entry.actor_email == "ops@example.com"
    assert entry.entity_id == to_string(job.id)
  end

  test "a job that already finished offers nothing to stop", %{conn: conn} do
    job = sync_job("MFS") |> with_state("completed")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute has_element?(view, "#stop-job-#{job.id}")
    assert render(view) =~ worker_name(SpaceWorker)
  end

  test "a job says what it acts on and who asked, without knowing the worker by name", %{
    conn: conn
  } do
    job = sync_job("MFS") |> with_state("available")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    # A queue of identical "SpaceWorker" rows says nothing about which space
    # each one reads: the scope comes from the job's own arguments.
    assert view |> element("#job-#{job.id}-scope") |> render() =~ "space MFS"
    assert view |> element("#job-#{job.id}-trigger") |> render() =~ "a test"
  end

  test "a job that takes no arguments says so rather than showing a blank", %{conn: conn} do
    {:ok, job} =
      ConfluencePhxMirror.Sync.SnapshotWorker.new(%{"trigger" => "the schedule"}) |> Oban.insert()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "available"])

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert view |> element("#job-#{job.id}-scope") |> render() =~ "—"
  end

  test "a worker that knows how to say its scope is printed as it wrote it", %{conn: conn} do
    {:ok, job} =
      ConfluencePhxMirror.Sync.SnapshotWorker.new(%{
        "trigger" => "the hourly schedule",
        "mode" => "incremental",
        "scope" => "the whole site, what changed"
      })
      |> Oban.insert()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "available"])

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert view |> element("#job-#{job.id}-scope") |> render() =~ "the whole site, what changed"
  end

  test "a job's own column carries what its record says, and links to that run's log", %{
    conn: conn
  } do
    job = sync_job("MFS") |> with_state("executing")
    run = run_of(job, "running", %{"pages" => 120, "changed" => 100, "phase" => "details"})

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    details = view |> element("#job-#{job.id}-details") |> render()

    assert details =~ "120 pages so far"
    assert details =~ "/admin/sync-log?run=#{run.id}"
    # The state is a column of its own; the cell does not repeat the badge.
    refute details =~ "badge"
  end

  test "the details column says why a job ended badly, in the open", %{conn: conn} do
    job = sync_job("MFS") |> with_state("executing")

    run_of(job, "failed", %{"pages" => 40},
      error: "the process running this sync stopped before it finished"
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    details = view |> element("#job-#{job.id}-details") |> render()

    assert details =~ "failed after 40 pages"
    assert details =~ "the process running this sync stopped before it finished"
  end

  test "a job whose record says nothing shows a dash rather than a blank", %{conn: conn} do
    job = sync_job("MFS") |> with_state("executing")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert view |> element("#job-#{job.id}-details") |> render() =~ "—"
  end

  test "the filter shows one state at a time", %{conn: conn} do
    running = sync_job("MFS") |> with_state("executing")
    finished = sync_job("ENG") |> with_state("completed")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    view |> element("#jobs-filter") |> render_change(%{"state" => "completed"})

    assert has_element?(view, "#jobs")
    refute has_element?(view, "#stop-job-#{running.id}")
    refute has_element?(view, "#stop-job-#{finished.id}")

    view |> element("#jobs-filter") |> render_change(%{"state" => "executing"})

    assert has_element?(view, "#stop-job-#{running.id}")
  end

  test "a job executing for hours is labelled long-running", %{conn: conn} do
    stale = sync_job("MFS") |> with_state("executing") |> attempted_hours_ago(4)

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert view |> element("#job-#{stale.id}") |> render() =~ "long-running"
  end

  test "a job that started an hour ago is simply working", %{conn: conn} do
    fresh = sync_job("MFS") |> with_state("executing") |> attempted_hours_ago(1)

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute view |> element("#job-#{fresh.id}") |> render() =~ "long-running"
  end

  defp sync_job(space_key) do
    {:ok, job} =
      SpaceWorker.new(%{"space_key" => space_key, "trigger" => "a test"}) |> Oban.insert()

    job
  end

  defp with_state(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    Repo.get!(Oban.Job, job.id)
  end

  defp attempted_hours_ago(job, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours, :hour)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [attempted_at: DateTime.truncate(at, :second)]
    )

    Repo.get!(Oban.Job, job.id)
  end

  defp state_of(job), do: Repo.get!(Oban.Job, job.id).state

  # The run a job started, as `Sync` writes it: the job id is the link the page
  # follows to show what the job is doing.
  defp run_of(job, status, stats, opts \\ []) do
    {:ok, run} =
      %SyncRun{}
      |> SyncRun.changeset(%{
        source: "confluence-demo",
        mode: "snapshot",
        scope: "space #{job.args["space_key"]}",
        status: status,
        job_id: job.id,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second),
        stats: stats,
        error: Keyword.get(opts, :error)
      })
      |> Repo.insert()

    run
  end

  defp worker_name(worker), do: worker |> to_string() |> String.split(".") |> List.last()
end
