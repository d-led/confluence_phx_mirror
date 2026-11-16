defmodule ConfluencePhxMirrorWeb.Admin.DashboardRunStatusTest do
  @moduledoc """
  The dashboard's status column, which is the most-read text on the screen.

  One table holds two kinds of line — a job waiting for its turn and a run that
  has finished — and a reader has to tell them apart at a glance. So every status
  a run can end in, and the queued lines above them, are pinned with the badge
  they are drawn as.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.{Gate, PageWorker, SyncRun}

  setup %{conn: conn} do
    {:ok, conn: log_in_admin(conn)}
  end

  # The gate is held for the length of this test for one reason: the page closes
  # every `running` run whose lease is free as abandoned, so a `running` row is
  # only on screen while a sync holds it — which is the honest reading of the
  # status, not a trick.
  test "every status a run can end in is drawn with its own badge", %{conn: conn} do
    badges = %{
      "succeeded" => "badge-success",
      "partial" => "badge-warning",
      "failed" => "badge-error",
      "cancelled" => "badge-neutral",
      "running" => "badge-info"
    }

    assert {:ok, _checked} =
             Gate.exclusive(fn _owner ->
               runs = Map.new(badges, fn {status, _badge} -> {status, run(status)} end)

               {:ok, view, _html} = live(conn, ~p"/admin")

               for {status, badge} <- badges do
                 assert has_element?(view, "tr#sync-run-#{runs[status].id} .#{badge}"),
                        "#{status} is not drawn as #{badge}"
               end
             end)
  end

  # A queued line has not happened yet, so it says what is true for the reader —
  # "scheduled", "retrying" — rather than Oban's scheduling vocabulary. Waiting
  # is the neutral colour: nothing has gone right or wrong yet.
  test "a job waiting its turn is a queued line, and says which kind of sync it is", %{
    conn: conn
  } do
    job = waiting_job()

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "tr#queued-#{job.id} .badge-ghost")

    row = view |> element("tr#queued-#{job.id}") |> render()
    assert row =~ "scheduled"
    assert row =~ "page"
    assert row =~ "page 884738"
  end

  test "a job waiting for its next attempt says so in warning colour", %{conn: conn} do
    job = waiting_job() |> with_state("retryable")

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "tr#queued-#{job.id} .badge-warning")

    assert view |> element("tr#queued-#{job.id}") |> render() =~ "retrying"
  end

  # A run that is still going has not ended; a finished one has a duration. The
  # start is a minute ago so these are the newest rows the table's limit keeps.
  defp run(status) do
    started_at = DateTime.add(DateTime.utc_now(), -60, :second)
    finished_at = if status == "running", do: nil, else: DateTime.add(started_at, 30, :second)

    %SyncRun{}
    |> SyncRun.changeset(%{
      source: "confluence-demo",
      mode: "snapshot",
      status: status,
      started_at: started_at,
      finished_at: finished_at,
      stats: %{"listed" => 3, "changed" => 2}
    })
    |> Repo.insert!()
  end

  # Scheduled ahead on the real queue, so the page lists it and no worker runs it.
  defp waiting_job do
    at = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, job} =
      PageWorker.new(%{"confluence_id" => 884_738, "trigger" => "a test"}, schedule_in: 3600)
      |> Oban.insert()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "scheduled", scheduled_at: DateTime.truncate(at, :second)]
    )

    Repo.get!(Oban.Job, job.id)
  end

  defp with_state(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    Repo.get!(Oban.Job, job.id)
  end
end
