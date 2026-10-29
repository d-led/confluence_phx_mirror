defmodule ConfluencePhxMirrorWeb.AdminSyncRunsExportTest do
  @moduledoc """
  `GET /admin/sync-runs/export` is the way out of the dashboard's eight-row
  window: the whole history, streamed.

  Who may ask is tested here. What the file contains is tested where the lines
  are made — the test adapter a controller test runs on cannot stream, so the
  batches the controller writes to the socket are read back in
  `ConfluencePhxMirror.Sync.HistoryTest`.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  setup do
    :ok
  end

  describe "who may download it" do
    test "a member is refused", %{conn: conn} do
      member = user_fixture()

      assert conn |> sign_in(member) |> get(~p"/admin/sync-runs/export") |> response(403)
    end

    test "an anonymous reader is refused", %{conn: conn} do
      assert conn |> get(~p"/admin/sync-runs/export") |> response(403)
    end

    test "an administrator gets a file, named for the day and the format", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> sign_in(admin)
        |> get(~p"/admin/sync-runs/export?format=csv")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="sync-runs-#{Date.utc_today() |> Date.to_iso8601()}.csv")
             ]
    end

    test "JSON lines is the same history under a different name", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> sign_in(admin)
        |> get(~p"/admin/sync-runs/export?format=jsonl")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-ndjson; charset=utf-8"]
    end
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
