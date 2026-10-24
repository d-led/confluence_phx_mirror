defmodule ConfluencePhxMirrorWeb.Admin.AuditJumpTest do
  @moduledoc """
  The audit log reads newest first, which is the order an operator wants — but
  a busy log is long, and the other end of it is where the older events and
  "Load older events" live. The page offers a jump there, and the jump lands.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, _} =
      Accounts.change_role(user_fixture(%{email: "jane@example.com"}), "admin", {:user, ops})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the log can be sent to its far end, and the end is there to land on", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/audit")

    assert has_element?(view, ~s{#audit-jump-to-end[href="#audit-log-end"]})
    assert has_element?(view, "#audit-log-end")
  end
end
