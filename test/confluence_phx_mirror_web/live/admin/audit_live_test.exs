defmodule ConfluencePhxMirrorWeb.Admin.AuditLiveTest do
  @moduledoc """
  The audit log has its own page: it reads like a log entry, not like a bare
  event name, and it filters the way an operator asks.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})
    jane = user_fixture(%{email: "jane@example.com"})
    {:ok, _} = Accounts.change_role(jane, "admin", {:user, ops})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "an event reads as a sentence with the account, the change and who made it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/audit")

    assert html =~ "Changed jane@example.com from member to admin"
    assert html =~ "ops@example.com"
  end

  test "the log can be filtered by account", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/audit")

    html = view |> form("#audit-filter", %{"q" => "nobody@example.com"}) |> render_change()

    assert html =~ "No events match this filter."
  end

  test "the log is reachable from the dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")

    assert html =~ "Open the audit log"
  end
end
