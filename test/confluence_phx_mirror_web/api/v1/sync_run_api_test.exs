defmodule ConfluencePhxMirrorWeb.Api.V1.SyncRunControllerTest do
  @moduledoc """
  The sync history on the API: a window at a time, newest first, with the total
  and the next window beside it — because the table behind it grows for as long
  as the mirror exists.

  Administrator-only, and the refusal is tested as carefully as the list: a
  run's error is what the node said when the sync broke.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SyncRun

  setup %{conn: conn} do
    older = run_fixture(~U[2026-10-01 10:00:00Z])
    newer = run_fixture(~U[2026-10-02 10:00:00Z])

    {:ok, conn: log_in_admin(conn), older: older, newer: newer}
  end

  test "an administrator reads the history newest first, one window at a time",
       %{conn: conn, newer: newer} do
    body = conn |> get(~p"/api/v1/sync-runs?limit=1") |> json_response(200)

    assert [run] = body["results"]
    assert run["id"] == newer.id
    assert run["mode"] == "page"
    assert run["trigger"] == "the admin dashboard, by admin@example.com"
    assert run["status"] == "succeeded"
    assert run["startedAt"] == "2026-10-02T10:00:00Z"
    assert body["start"] == 0
    assert body["limit"] == 1
    assert body["size"] == 1
    assert body["_links"]["next"] =~ "start=1"
  end

  test "the next window is where the client left off", %{conn: conn, older: older} do
    body = conn |> get(~p"/api/v1/sync-runs?start=1&limit=1") |> json_response(200)

    assert [run] = body["results"]
    assert run["id"] == older.id
    assert body["start"] == 1
  end

  test "a window larger than the mirror serves comes back as the window it served",
       %{conn: conn} do
    body = conn |> get(~p"/api/v1/sync-runs?limit=10000") |> json_response(200)

    assert body["limit"] == 500
  end

  test "a reader's token is refused", %{conn: conn} do
    {:ok, plain, _token} = reader_token()

    body =
      conn
      |> put_req_header("authorization", "Bearer #{plain}")
      |> get(~p"/api/v1/sync-runs")
      |> json_response(403)

    assert body["error"] == "not_authorized"

    body =
      conn
      |> put_req_header("authorization", "Bearer #{plain}")
      |> get(~p"/api/v1/sync-runs/export?format=jsonl")
      |> json_response(403)

    assert body["error"] == "not_authorized"
  end

  defp reader_token do
    user = user_fixture(%{role: "member"})
    Accounts.create_api_token(user, "a test", {:system, "test"})
  end

  # A run that finished a minute after it started, in the shape the sync writes
  # them: one page asked for by a page view.
  defp run_fixture(started_at) do
    %SyncRun{}
    |> SyncRun.changeset(%{
      source: "confluence-http",
      mode: "page",
      scope: "page 1002",
      trigger: "the admin dashboard, by admin@example.com",
      status: "succeeded",
      started_at: started_at,
      finished_at: DateTime.add(started_at, 60, :second),
      stats: %{"pages" => 1, "changed" => 1}
    })
    |> Repo.insert!()
  end
end
