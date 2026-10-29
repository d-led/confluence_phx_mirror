defmodule ConfluencePhxMirrorWeb.Admin.AuditLiveStreamTest do
  @moduledoc """
  An operator leaves the log open while other people work, so it keeps up on its
  own: an event the mirror records while the page is open appears without a
  reload — unless the reader has narrowed the log, whose filter that event would
  contradict.
  """

  # The log is one global broadcast, so these tests must not run beside another
  # page that is listening to it.
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts

  setup %{conn: conn} do
    ops = user_fixture(%{role: "admin"})
    jane = user_fixture()

    conn = Plug.Test.init_test_session(conn, %{"user_id" => ops.id})

    {:ok, conn: conn, ops: ops, jane: jane}
  end

  test "an event that happens while the log is open appears in it", %{
    conn: conn,
    ops: ops,
    jane: jane
  } do
    {:ok, view, html} = live(conn, ~p"/admin/audit")
    refute html =~ "Changed #{jane.email} from member to admin"

    promote_to_admin(jane, ops)

    assert render(view) =~ "Changed #{jane.email} from member to admin"
  end

  test "a log the reader has narrowed does not grow behind their back", %{
    conn: conn,
    ops: ops,
    jane: jane
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/audit?action=login")

    promote_to_admin(jane, ops)

    refute render(view) =~ "Changed #{jane.email} from member to admin"
  end

  defp promote_to_admin(jane, ops) do
    {:ok, _} = Accounts.change_role(jane, "admin", {:user, ops})
  end
end
