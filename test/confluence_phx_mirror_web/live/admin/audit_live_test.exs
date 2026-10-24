defmodule ConfluencePhxMirrorWeb.Admin.AuditLiveTest do
  @moduledoc """
  The audit log has its own page: it reads like a log entry, not like a bare
  event name, and it filters the way an operator asks.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Audit.Entry

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

  test "a filtered log says what is searched and offers a way back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/audit?q=nobody@example.com")

    assert has_element?(view, "#audit-clear")
    assert has_element?(view, "#audit-log", "Every word has to match")
  end

  test "an unfiltered log has nothing to clear", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/audit")

    refute has_element?(view, "#audit-clear")
  end

  test "an event whose facts are nested still reads as a line", %{conn: conn} do
    # A queued job carries its arguments as a map and a settings change carries
    # a diff, because the row keeps them whole for the JSON API. The log says
    # the pairs; it must not try to print the map as a word.
    Audit.log(
      {:system, "test"},
      Entry.new("sync.dequeued", "job", 7, %{
        "args" => %{"space_key" => "MFS", "trigger" => "a UI check"}
      })
    )

    {:ok, _view, html} = live(conn, ~p"/admin/audit")

    assert html =~ "space_key=MFS, trigger=a UI check"
  end

  test "a long map of facts is cut off and counted", %{conn: conn} do
    changes = Map.new(1..5, &{"reader.field#{&1}", "default"})

    Audit.log(
      {:system, "test"},
      Entry.new("settings.updated", "settings", "reader", %{"changes" => changes})
    )

    {:ok, _view, html} = live(conn, ~p"/admin/audit")

    assert html =~ "reader.field1=default, reader.field2=default, reader.field3=default +2"
  end
end
