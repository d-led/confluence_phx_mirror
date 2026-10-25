defmodule ConfluencePhxMirrorWeb.Admin.DashboardCSPTest do
  @moduledoc """
  LiveDashboard ships one inline script (`window.LiveDashboard = {customHooks…}`)
  that its own bundle reads; without it the dashboards paint and then do
  nothing. The reader pages must never allow inline script, so the exception is
  one route wide — and it is worth a test of its own, because relaxing a policy
  is the kind of change that quietly stops being true.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the runtime dashboard may run its own inline script", %{conn: conn} do
    [policy] = conn |> get("/admin/runtime") |> get_resp_header("content-security-policy")

    assert policy =~ "script-src 'self' 'unsafe-inline'"
  end

  test "a reader page may not", %{conn: conn} do
    [policy] = conn |> get(~p"/") |> get_resp_header("content-security-policy")

    refute policy =~ "script-src 'self' 'unsafe-inline'"
    assert policy =~ "script-src 'self';"
  end
end
