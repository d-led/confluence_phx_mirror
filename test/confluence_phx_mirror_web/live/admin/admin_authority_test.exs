defmodule ConfluencePhxMirrorWeb.Live.AdminAuthorityTest do
  @moduledoc """
  An admin screen asks who is acting when the action is taken, not only when the
  page was opened — a tab left open must not outlive the administration it was
  opened with.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts

  setup %{conn: conn} do
    keeper = user_fixture(%{email: "keeper@example.com", role: "admin"})
    reader = user_fixture(%{email: "reader@example.com"})

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"user_id" => keeper.id}),
     keeper: keeper,
     reader: reader}
  end

  defp promote(view, reader),
    do: render_submit(view, "change_role", %{"user_id" => reader.id, "role" => "admin"})

  test "an administrator who still is one carries on undisturbed", %{conn: conn, reader: reader} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert promote(view, reader) =~ "Role updated."
    assert Accounts.get_user(reader.id).role == "admin"
  end

  test "a demoted administrator loses the page on the next action", %{
    conn: conn,
    keeper: keeper,
    reader: reader
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/users")
    {:ok, _} = Accounts.change_role(keeper, "member", {:system, "another administrator"})

    assert {:error, {:redirect, %{to: "/"}}} = promote(view, reader)
    assert Accounts.get_user(reader.id).role == "member"
  end

  test "a deleted administrator loses the page on the next action", %{
    conn: conn,
    keeper: keeper,
    reader: reader
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/users")
    ConfluencePhxMirror.Repo.delete!(keeper)

    assert {:error, {:redirect, %{to: "/"}}} = promote(view, reader)
    assert Accounts.get_user(reader.id).role == "member"
  end
end
