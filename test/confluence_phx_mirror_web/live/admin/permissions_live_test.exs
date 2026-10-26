defmodule ConfluencePhxMirrorWeb.Live.AdminPermissionsLiveTest do
  @moduledoc """
  The permissions screen answers two questions and never confuses them: which
  spaces are narrowed, and who narrows a particular one.

  "No rows" and "everybody" are the answers an administrator mixes up, so the
  empty case is a sentence (*open*), not a list with nothing in it.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  @moduletag :empty_mirror

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

  # The bug this guards: a personal space has no permission rows at all, and an
  # empty table there means one reader, not everybody.
  test "a personal space is not open — it belongs to one account", %{conn: conn} do
    space = space_fixture(%{key: "~5F057CBE0B38B10022628D68", type: "personal"})

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    assert has_element?(view, "#space-personal-#{space.id}")
    refute has_element?(view, "#space-open-#{space.id}")

    view |> element("#inspect-space-#{space.id}") |> render_click()

    assert has_element?(view, "#space-access-personal")
    refute has_element?(view, "#space-access-open")
    assert render(view) =~ "5f057cbe0b38b10022628d68"
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
  defp granted_row(type, key), do: ~s{[id="space-granted-#{type}-#{key}"]}
  defp add_person(key), do: ~s{[id="space-grant-add-person-#{key}"]}
  defp revoke_row(type, key), do: ~s{[id="space-revoke-#{type}-#{key}"]}

  test "a restricted page is named under its space, and inspecting it says who may read it", %{
    conn: conn
  } do
    space = a_space_read_by("anyone@example.com")
    restricted = page_fixture(space, %{title: "Salaries"})
    page_fixture(space, %{title: "Handbook"})

    {:ok, _} =
      Mirror.replace_page_restrictions(restricted, [
        %{operation: "read", subject_type: "group", subject_key: "leadership"}
      ])

    {:ok, view, _html} = live(conn, ~p"/admin/permissions")

    view |> element("#inspect-space-#{space.id}") |> render_click()

    # Only the page that is narrowed is worth naming; the space's other pages
    # inherit the space's answer.
    assert has_element?(view, "#restricted-page-#{restricted.id}")
    refute render(view) =~ "Handbook"

    view |> element("#inspect-page-#{restricted.id}") |> render_click()

    assert has_element?(view, "#page-access-panel")
    assert has_element?(view, "#page-access-group-leadership")

    # And the space's own readers are not added to it: a restricted page is
    # readable only by who it lists. The space panel is still open behind it, so
    # the question is asked of the page panel.
    refute view |> element("#page-access-panel") |> render() =~ "anyone@example.com"
  end

  describe "granting access here" do
    test "a person the site names can be added to a narrow space, and removed again", %{
      conn: conn
    } do
      space = a_space_read_by("inside@example.com")
      person = "557058:guest-reader"
      a_person_named(person, "Guest Reader")

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()

      assert has_element?(view, "#space-granted-none")

      view |> element("#space-open-grant") |> render_click()
      view |> element("#space-grant-search") |> render_change(%{"term" => "guest"})
      view |> element(add_person(person)) |> render_click()

      assert has_element?(view, granted_row("user", person))
      refute has_element?(view, "#space-granted-none")
      assert person in Enum.map(Mirror.space_grants_here(space), & &1.subject_key)

      view |> element(revoke_row("user", person)) |> render_click()

      assert has_element?(view, "#space-granted-none")
      assert Mirror.space_grants_here(space) == []
    end

    test "a group the sync read can be added too", %{conn: conn} do
      space = a_space_read_by("inside@example.com")
      {:ok, _} = Mirror.replace_group_members("all-staff", [%{email: "someone@example.com"}])

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()
      view |> element("#space-open-grant") |> render_click()
      html = view |> element("#space-grant-search") |> render_change(%{"term" => "all-staff"})

      assert html =~ "all-staff"

      view |> element(~s{[id="space-grant-add-group-all-staff"]}) |> render_click()

      assert has_element?(view, granted_row("group", "all-staff"))
    end

    test "a search that matches nobody says why", %{conn: conn} do
      space = a_space_read_by("inside@example.com")

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()
      view |> element("#space-open-grant") |> render_click()
      view |> element("#space-grant-search") |> render_change(%{"term" => "nobody-here"})

      assert has_element?(view, "#space-grant-no-matches")
    end
  end

  # A refusal is a sentence beside the control, not an error page: the click stays
  # where it was. Each case is a click a stale screen can still send.
  describe "a grant the mirror refuses" do
    test "on an open space there is nothing to widen", %{conn: conn} do
      space = space_fixture(%{key: "OPENSPACE"})

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()

      html =
        render_click(view, "grant_add", %{
          "level" => "space",
          "subject_type" => "user",
          "subject_key" => "guest@example.com"
        })

      assert html =~ "This space is open — there is nothing to widen."
      assert Mirror.space_grants_here(space) == []
    end

    test "a reader the mirror has never seen asks for a sync", %{conn: conn} do
      space = a_space_read_by("inside@example.com")

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()

      html =
        render_click(view, "grant_add", %{
          "level" => "space",
          "subject_type" => "user",
          "subject_key" => "never-seen@example.com"
        })

      assert html =~ "The mirror has not seen never-seen@example.com yet — run a sync."
      assert Mirror.space_grants_here(space) == []
    end

    test "removing a grant that is already gone says so", %{conn: conn} do
      space = a_space_read_by("inside@example.com")

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()

      html =
        render_click(view, "grant_revoke", %{
          "level" => "space",
          "subject_type" => "group",
          "subject_key" => "confluence-users"
        })

      assert html =~ "confluence-users is not granted here."
    end

    test "an unrestricted page has nothing to widen either", %{conn: conn} do
      space = a_space_read_by("inside@example.com")
      page = page_fixture(space, %{title: "Handbook"})

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()
      render_click(view, "inspect_page", %{"page_id" => to_string(page.id)})

      html =
        render_click(view, "grant_add", %{
          "level" => "page",
          "subject_type" => "user",
          "subject_key" => "guest@example.com"
        })

      assert html =~ "This page is unrestricted — there is nothing to widen."
      assert Mirror.page_grants(page).granted == []
    end
  end

  describe "granting access on a page" do
    test "a person can be added to a restricted page and removed again", %{conn: conn} do
      space = space_fixture(%{key: "PAGEDLG"})
      page = page_fixture(space, %{title: "Salaries"})
      person = "557058:page-guest"
      a_person_named(person, "Page Guest")

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"}
        ])

      {:ok, view, _html} = live(conn, ~p"/admin/permissions")
      view |> element("#inspect-space-#{space.id}") |> render_click()
      view |> element("#inspect-page-#{page.id}") |> render_click()

      assert has_element?(view, "#page-granted-none")

      view |> element("#page-open-grant") |> render_click()
      view |> element("#page-grant-search") |> render_change(%{"term" => "page guest"})
      view |> element(~s{[id="page-grant-add-person-#{person}"]}) |> render_click()

      assert has_element?(view, ~s{[id="page-granted-user-#{person}"]})
      assert [%{subject_key: ^person}] = Mirror.page_grants(page).granted

      view |> element(~s{[id="page-revoke-user-#{person}"]}) |> render_click()

      assert Mirror.page_grants(page).granted == []
    end
  end

  defp a_person_named(account_id, name) do
    page_fixture(space_fixture(), %{author_name: name, author_account_id: account_id})
  end

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
