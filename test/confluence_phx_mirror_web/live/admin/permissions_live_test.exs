defmodule ConfluencePhxMirrorWeb.Live.AdminPermissionsLiveTest do
  @moduledoc """
  The permissions screen answers two questions and never confuses them: which
  spaces are narrowed, and who narrows a particular one.

  "No rows" and "everybody" are the answers an administrator mixes up, so the
  empty case is a sentence (*open*), not a list with nothing in it.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror

  test "a space shows how many groups and people may read it", %{conn: conn} do
    space = a_space_read_by("readers@example.com")

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    assert has_element?(view, "#space-row-#{space.id}")
    assert render(view) =~ "1 group"
  end

  test "a space with no mirrored permissions says it is open", %{conn: conn} do
    space = space_fixture()

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    assert has_element?(view, "#space-open-#{space.id}")
  end

  test "inspecting a space names the groups, the people and the anonymous readers", %{conn: conn} do
    reader = user_fixture(%{email: "known@example.com"})
    space = a_space_read_by("known@example.com", anonymous: true)

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    view |> element("#inspect-space-#{space.id}") |> render_click()

    assert has_element?(view, "#space-access-group-confluence-users")
    assert has_element?(view, subject_row("known@example.com"))
    assert render(view) =~ Accounts.get_user(reader.id).email
    assert has_element?(view, "#space-access-anonymous")
  end

  test "a person the mirror has no account for is still named", %{conn: conn} do
    space = a_space_read_by("no.account@example.com")

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    html = view |> element("#inspect-space-#{space.id}") |> render_click()

    assert html =~ "no.account@example.com"
    assert html =~ "no account here yet"
  end

  test "inspecting a space with nothing mirrored says so instead of listing nothing", %{
    conn: conn
  } do
    space = space_fixture()

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    view |> element("#inspect-space-#{space.id}") |> render_click()

    assert has_element?(view, "#space-access-open")
    refute has_element?(view, "#space-access-group-confluence-users")
  end

  test "the list is filtered by key, in the database", %{conn: conn} do
    alpha = space_fixture(%{key: "ALPHA", name: "Alpha handbook"})
    space_fixture(%{key: "BETA", name: "Beta handbook"})

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    html = view |> element("#space-filter") |> render_change(%{"q" => "ALPHA"})

    assert html =~ alpha.name
    assert html =~ "Alpha handbook"
    refute html =~ "Beta handbook"
  end

  # A subject key can be an e-mail or "557058:…", neither of which a CSS
  # selector takes raw, so the row is found by its attribute.
  defp subject_row(key), do: ~s{[id="space-access-user-#{key}"]}

  defp a_space_read_by(email, opts \\ []) do
    space = space_fixture(%{key: "READ#{System.unique_integer([:positive])}"})

    permissions =
      [%{operation: "read", subject_type: "group", subject_key: "confluence-users"}] ++
        [%{operation: "read", subject_type: "user", subject_key: email}] ++
        if(opts[:anonymous],
          do: [%{operation: "read", subject_type: "anonymous", subject_key: ""}],
          else: []
        )

    {:ok, _} = Mirror.replace_space_permissions(space, permissions)
    space
  end
end
