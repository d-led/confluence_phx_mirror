defmodule ConfluencePhxMirrorWeb.Live.AdminAuthorityTest do
  @moduledoc """
  An admin screen asks who is acting when the action is taken, not only when the
  page was opened — a tab left open must not outlive the administration it was
  opened with.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.{Mirror, Repo, Trash}
  alias ConfluencePhxMirror.Mirror.Page

  setup %{conn: conn} do
    keeper = user_fixture(%{role: "admin"})
    # A second administrator, so the keeper may step down — the mirror always
    # keeps one, which is a rule of its own.
    user_fixture(%{role: "admin"})
    reader = user_fixture()

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
    Repo.delete!(keeper)

    assert {:error, {:redirect, %{to: "/"}}} = promote(view, reader)
    assert Accounts.get_user(reader.id).role == "member"
  end

  test "a member cannot open the trash, the one screen that deletes for good", %{
    conn: conn,
    reader: reader
  } do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => reader.id})

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/trash")
  end

  # Oban's own rows name every job the mirror runs, and stopping one ends a
  # sync, so the page is administration like the rest of `/admin`.
  test "a member cannot open the jobs page", %{conn: conn, reader: reader} do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => reader.id})

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/jobs")
  end

  test "a demoted administrator cannot empty a trash left open in a tab", %{
    conn: conn,
    keeper: keeper
  } do
    space = space_fixture(%{key: "GONE"})
    page = page_fixture(space)
    assert Mirror.trash_space(space) == 1

    {:ok, view, _html} = live(conn, ~p"/admin/trash")
    {:ok, _} = Accounts.change_role(keeper, "member", {:system, "another administrator"})

    assert {:error, {:redirect, %{to: "/"}}} = view |> element("#empty-trash") |> render_click()

    assert Repo.get(Page, page.id)
    assert Trash.spaces() != []
  end
end
