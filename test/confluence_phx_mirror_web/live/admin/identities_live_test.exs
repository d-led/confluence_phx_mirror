defmodule ConfluencePhxMirrorWeb.Live.AdminIdentitiesLiveTest do
  @moduledoc """
  The Confluence identities the mirror knows, and the one place an administrator
  says "this identity is this person".

  A site names a hundred thousand people, so the list is searched and paged
  rather than drawn; linking is a search and a click, from either side — start
  at the identity and find its account, or start at the account and find what
  else the content names for that person.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror

  @guest "5f057cbe0b38b10022628d68"

  test "the people Confluence's content names are listed with their groups", %{conn: conn} do
    a_person_named(@guest, "Jane Doe")

    {:ok, _view, html} = live(conn, ~p"/admin/identities")

    assert html =~ "People from Confluence"
    assert html =~ "Jane Doe"
    assert html =~ @guest
    assert html =~ "confluence-users"
    assert html =~ "not a mirror account"
  end

  describe "linking" do
    test "from an identity: the picker finds the account by search, and links on a click", %{
      conn: conn
    } do
      reader = user_fixture(%{email: "linked.reader@example.com"})
      other = user_fixture(%{email: "other.person@example.com"})
      a_person_named(@guest)

      {:ok, view, _html} = live(conn, ~p"/admin/identities")

      assert view |> element("#link-1") |> render_click() =~ "to an account"

      view |> element("#account-search-form") |> render_change(%{"q" => "linked.reader"})

      assert has_element?(view, "#link-account-#{reader.id}")
      refute has_element?(view, "#link-account-#{other.id}")

      html = view |> element("#link-account-#{reader.id}") |> render_click()

      assert html =~ "#{@guest} is now linked.reader@example.com"
      assert Accounts.get_user(reader.id).identity_account_ids == [@guest]
      assert has_element?(view, "#unlink-1")

      html = view |> element("#unlink-1") |> render_submit()

      assert html =~ "is no longer"
      assert Accounts.get_user(reader.id).identity_account_ids == []
    end

    test "from an account: both identities the content names can be linked to it", %{
      conn: conn
    } do
      second = "557058:12861f68-8857-4349-927d-e49dfb30bd52"
      account = user_fixture(%{email: "both.reader@example.com"})
      a_person_named(@guest, "Guest Ledentsov")
      a_person_named(second, "Dmitry Ledentsov")

      {:ok, view, _html} = live(conn, ~p"/admin/identities")

      view |> element("#account-pick-form") |> render_change(%{"q" => "both.reader"})

      html = view |> element("#link-identity-#{account.id}") |> render_click()

      assert has_element?(view, "#identity-picker")
      assert html =~ "Add an identity to"
      assert has_element?(view, identity_row(@guest))
      assert has_element?(view, identity_row(second))

      view |> element(identity_row(@guest)) |> render_click()
      view |> element("#account-pick-form") |> render_change(%{"q" => "both.reader"})
      view |> element("#link-identity-#{account.id}") |> render_click()
      html = view |> element(identity_row(second)) |> render_click()

      assert html =~ "2 linked"

      assert Enum.sort(Accounts.get_user(account.id).identity_account_ids) ==
               Enum.sort([@guest, second])
    end

    test "the picker does not offer an identity another account already holds", %{conn: conn} do
      holder = user_fixture(%{email: "holder.reader@example.com"})
      account = user_fixture(%{email: "second.reader@example.com"})
      a_person_named(@guest)

      {:ok, _} = Accounts.link_identity(holder, @guest, {:user, an_admin()})

      {:ok, view, _html} = live(conn, ~p"/admin/identities")
      view |> element("#account-pick-form") |> render_change(%{"q" => "second.reader"})
      view |> element("#link-identity-#{account.id}") |> render_click()

      html = view |> element("#identity-search-form") |> render_change(%{"q" => @guest})

      assert html =~ "already holder.reader@example.com"
      refute has_element?(view, identity_row(@guest))
    end

    test "a search that matches no account says so", %{conn: conn} do
      a_person_named(@guest)

      {:ok, view, _html} = live(conn, ~p"/admin/identities")
      view |> element("#link-1") |> render_click()

      html = view |> element("#account-search-form") |> render_change(%{"q" => "nobody-here"})

      assert html =~ "No account matches"
    end
  end

  test "the list is searched by name or account id, not dumped", %{conn: conn} do
    a_person_named(@guest, "Guest Ledentsov")
    a_person_named("557058:someone-else", "Other Person")

    {:ok, view, _html} = live(conn, ~p"/admin/identities")

    assert view |> element("#identity-filter") |> render_change(%{"q" => "guest"}) =~
             "Guest Ledentsov"

    html = view |> element("#identity-filter") |> render_change(%{"q" => "someone-else"})

    assert html =~ "Other Person"
    refute html =~ "Guest Ledentsov"

    html = view |> element("#identity-filter") |> render_change(%{"q" => "nobody-at-all"})

    assert html =~ "No author mirrored yet"
  end

  # A Confluence account id can look like "557058:12861f68-…", and a ":" is not
  # something a CSS selector takes raw, so the row is found by its attribute.
  defp identity_row(account_id), do: ~s{[id="link-candidate-#{account_id}"]}

  # A person is somebody the content or a group names; the party line here is
  # "this identity exists and is linkable".
  defp a_person_named(account_id, name \\ "Guest Ledentsov") do
    space = space_fixture()
    page_fixture(space, %{author_name: name, author_account_id: account_id})

    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [
        %{account_id: account_id, display_name: name}
      ])
  end

  defp an_admin, do: user_fixture(%{email: "linking.admin@example.com", role: "admin"})
end
