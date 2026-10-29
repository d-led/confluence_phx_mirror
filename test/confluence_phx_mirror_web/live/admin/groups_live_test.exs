defmodule ConfluencePhxMirrorWeb.AdminGroupsLiveTest do
  @moduledoc """
  The group screen an administrator audits access from: the groups the sync
  read, who is in one, and what that group decides.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false
  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.PeopleWorker

  setup %{conn: conn} do
    demo_snapshot!()
    %{conn: log_in_admin(conn)}
  end

  test "the directory lists the groups the last sync read, with their sizes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    assert has_element?(view, "#group-confluence-users")
    assert has_element?(view, "#group-product-team")
    assert has_element?(view, "#group-confluence-admins")
  end

  test "a group opens on its members and on what it decides", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/groups/confluence-users")

    assert has_element?(view, "#group-members")
    assert has_element?(view, "#group-members tbody tr")

    # The demo restricts a page to this group, which is what the audit needs to
    # see: the membership and the grant, side by side.
    assert has_element?(view, "#group-pages li")
  end

  test "a group nothing names says it decides nothing", %{conn: conn} do
    {:ok, _} = Mirror.replace_group_members("quiet-group", [%{email: "quiet@example.com"}])

    {:ok, view, _html} = live(conn, ~p"/admin/groups/Quiet-group")

    assert has_element?(view, "#group-access-empty")
    refute has_element?(view, "#group-spaces")
  end

  test "the filter is the address, and it narrows the directory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#group-filter") |> render_change(%{"q" => "product"})

    assert_patch(view, ~p"/admin/groups?page=1&q=product")
    assert has_element?(view, "#group-product-team")
    refute has_element?(view, "#group-confluence-users")
  end

  test "a group the sync no longer lists sends the reader back to the directory", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/admin/groups"}}} =
             live(conn, ~p"/admin/groups/vanished-group")
  end

  test "an administrator asks Confluence for the groups again, without a page read", %{conn: conn} do
    admin = Accounts.ensure_admin!()
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#sync-groups") |> render_click()

    assert has_element?(view, "#groups-job-queued")

    assert_enqueued(
      worker: PeopleWorker,
      args: %{"trigger" => "the groups screen, by #{admin.email}"}
    )
  end
end
