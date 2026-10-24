defmodule ConfluencePhxMirrorWeb.Live.AdminUsersLiveTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror

  defp change_role(view, user, role) do
    render_submit(view, "change_role", %{"user_id" => to_string(user.id), "role" => role})
  end

  test "accounts come from sign-in, not from this screen", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Account provisioning"
    refute html =~ "create-user-form"
  end

  test "the people Confluence's content names are listed with their groups", %{conn: conn} do
    space = space_fixture()

    page_fixture(space, %{author_name: "Jane Doe", author_account_id: "557058:jane"})
    {:ok, _} = Mirror.replace_subject_groups(%{account_id: "557058:jane"}, ["confluence-users"])

    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "People from Confluence"
    assert html =~ "Jane Doe"
    assert html =~ "confluence-users"
    refute html =~ "has an account"
  end

  test "protected administrators cannot be demoted", %{conn: conn} do
    admin = Accounts.ensure_admin!()
    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Protected"
    assert {:error, :protected_admin} = Accounts.change_role(admin, "member", {:system, "test"})
  end

  test "an admin changes someone's role", %{conn: conn} do
    reader = user_fixture(%{email: "role.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert change_role(view, reader, "admin") =~ "Role updated."

    assert Accounts.get_user(reader.id).role == "admin"
  end

  test "the screen offers no way to mint a token for somebody else", %{conn: conn} do
    reader = user_fixture(%{email: "token.reader@example.com"})
    {:ok, view, html} = live(conn, ~p"/admin/users")

    # A token acts as its owner, so creating one is that person's own act: the
    # admin screen lists theirs and can revoke, and points at /profile for the
    # rest. A `create_token` event here is what this test exists to prevent.
    refute has_element?(view, "#new-token-#{reader.id}")
    refute has_element?(view, "form[phx-submit=create_token]")
    assert html =~ "creates their own tokens"
    assert Accounts.list_api_tokens(reader) == []
  end

  test "the screen still lets an administrator revoke a leaked token", %{conn: conn} do
    reader = user_fixture(%{email: "leaked.reader@example.com"})
    {:ok, _plain, token} = Accounts.create_api_token(reader, "leaked", {:system, "test"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "revoke_token", %{
        "user_id" => to_string(reader.id),
        "token_id" => to_string(token.id)
      })

    assert html =~ "Token revoked."
    assert Accounts.list_api_tokens(reader) == []
  end

  test "an admin revokes a token", %{conn: conn} do
    reader = user_fixture(%{email: "revoke.reader@example.com"})
    {:ok, _plain, token} = Accounts.create_api_token(reader, "old", {:system, "test"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "revoke_token", %{
        "user_id" => to_string(reader.id),
        "token_id" => to_string(token.id)
      })

    assert html =~ "Token revoked."
    assert Accounts.list_api_tokens(reader) == []
  end

  test "revoking a token that is already gone says so", %{conn: conn} do
    reader = user_fixture(%{email: "gone.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "revoke_token", %{
        "user_id" => to_string(reader.id),
        "token_id" => "0"
      })

    assert html =~ "Token not found."
  end

  test "an admin grants one group at a time, from the synced names", %{conn: conn} do
    reader = user_fixture(%{email: "groups.reader@example.com"})
    {:ok, _} = Mirror.replace_group_members("incident-responders", [])
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      view
      |> element("#group-picker-form-#{reader.id}")
      |> render_submit(%{"user_id" => to_string(reader.id), "group" => "incident-responders"})

    assert html =~ "incident-responders is granted here."
    assert Accounts.get_user(reader.id).groups == ["incident-responders"]

    html =
      render_submit(view, "remove_group", %{
        "user_id" => to_string(reader.id),
        "group" => "incident-responders"
      })

    assert html =~ "no longer granted here"
    assert Accounts.get_user(reader.id).groups == []
  end

  test "a group no sync has read can still be granted, and a blank is refused", %{conn: conn} do
    reader = user_fixture(%{email: "free.group.reader@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "add_group", %{
        "user_id" => to_string(reader.id),
        "group" => "  On-Call  "
      })

    assert html =~ "on-call is granted here."
    assert Accounts.get_user(reader.id).groups == ["on-call"]

    html = render_submit(view, "add_group", %{"user_id" => to_string(reader.id), "group" => " "})

    assert html =~ "Choose a group first."
    assert Accounts.get_user(reader.id).groups == ["on-call"]
  end

  test "an admin issues a service token and sees it exactly once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      view
      |> element("#create-service-token")
      |> render_submit(%{"name" => "confluence-webhooks", "scope" => "webhook"})

    assert html =~ "Service token created"
    assert html =~ "New token for service: confluence-webhooks"
    assert [%{name: "confluence-webhooks", scope: "webhook"}] = Accounts.list_service_tokens()
  end

  test "an admin revokes a service token", %{conn: conn} do
    {:ok, _plain, token} = Accounts.create_service_token("old", "webhook", {:system, "test"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html = render_submit(view, "revoke_service_token", %{"token_id" => to_string(token.id)})

    assert html =~ "Service token revoked."
    assert Accounts.list_service_tokens() == []
  end

  test "revoking a service token that is already gone says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html = render_submit(view, "revoke_service_token", %{"token_id" => "0"})

    assert html =~ "Service token not found."
  end

  test "a protected administrator stays an administrator even if the event arrives", %{
    conn: conn
  } do
    admin = Accounts.ensure_admin!()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert change_role(view, admin, "member") =~ "A seeded or bootstrap administrator stays one."
    assert Accounts.get_user(admin.id).role == "admin"
  end

  describe "identity linking" do
    @guest "5f057cbe0b38b10022628d68"

    test "an administrator links a Confluence identity to an account, and unlinks it", %{
      conn: conn
    } do
      reader = user_fixture(%{email: "linked.reader@example.com"})
      a_person_named(@guest)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html =
        view
        |> element("#link-1")
        |> render_submit(%{"account_id" => @guest, "email" => reader.email})

      assert html =~ "is now linked.reader@example.com"
      assert html =~ "linked to"
      assert Accounts.get_user(reader.id).identity_account_ids == [@guest]

      html = view |> element("#unlink-1") |> render_submit()

      assert html =~ "is no longer"
      assert Accounts.get_user(reader.id).identity_account_ids == []
    end

    test "linking to an address that is not an account says so", %{conn: conn} do
      a_person_named(@guest)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html =
        view
        |> element("#link-1")
        |> render_submit(%{"account_id" => @guest, "email" => "nobody@example.com"})

      assert html =~ "No mirror account has that e-mail address."
    end

    # A person is somebody the content or a group names; the party line here is
    # "this identity exists and is linkable".
    defp a_person_named(account_id) do
      space = space_fixture()
      page_fixture(space, %{author_name: "Guest Ledentsov", author_account_id: account_id})

      {:ok, _} =
        Mirror.replace_group_members("confluence-users", [
          %{account_id: account_id, display_name: "Guest Ledentsov"}
        ])
    end
  end

  describe "moderation" do
    test "a seeded administrator's row offers no Delete, and no event deletes it", %{conn: conn} do
      previously = Application.get_env(:confluence_phx_mirror, :admins)
      Application.put_env(:confluence_phx_mirror, :admins, ["boss@example.com"])
      on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previously) end)

      boss = user_fixture(%{email: "boss@example.com", role: "admin"})
      # A second administrator, so being "the last one" is not what protects it.
      user_fixture(%{email: "colleague@example.com", role: "admin"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "button#delete-#{boss.id}[disabled]")

      html = render_submit(view, "delete_user", %{"user_id" => to_string(boss.id)})

      assert html =~ "seeded or bootstrap administrator"
      assert Accounts.get_user(boss.id)
    end

    test "an administrator bans a reader, and a banned reader cannot be deleted", %{conn: conn} do
      reader = user_fixture(%{email: "banned.reader@example.com"})
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert view |> element("#ban-form-#{reader.id}") |> render_submit() =~ "is banned"
      assert has_element?(view, "#banned-#{reader.id}")
      assert has_element?(view, "#unban-#{reader.id}")

      html = render_submit(view, "delete_user", %{"user_id" => to_string(reader.id)})

      assert html =~ "cannot be deleted"
      assert Accounts.get_user(reader.id)
    end

    test "a banned reader stays out until an administrator lifts the ban", %{conn: conn} do
      reader = user_fixture(%{email: "banned.again@example.com"})
      {:ok, _} = Accounts.ban(reader, {:system, "test"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert view |> element("#unban-form-#{reader.id}") |> render_submit() =~ "is unbanned"
      refute User.banned?(Accounts.get_user(reader.id))
    end

    test "deleting an account here removes it", %{conn: conn} do
      reader = user_fixture(%{email: "gone.reader@example.com"})
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html = render_submit(view, "delete_user", %{"user_id" => to_string(reader.id)})

      assert html =~ "is deleted"
      refute Accounts.get_user(reader.id)
    end

    test "an account the site deleted says so, and the mirror refuses it", %{conn: conn} do
      reader = user_fixture(%{email: "site.gone@example.com"})
      Accounts.reconcile_site_status("557058:site.gone", "site.gone@example.com", :deleted)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#deleted-on-site-#{reader.id}")
      assert view |> render() =~ "no longer has this account"
    end
  end

  describe "disablement" do
    test "an administrator switches an account off here, and the flag shows", %{conn: conn} do
      reader = user_fixture(%{email: "off.reader@example.com"})
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> element("#disable-form-#{reader.id}") |> render_submit()

      assert has_element?(view, "#disabled-here-#{reader.id}")
      assert User.disabled_here?(Accounts.get_user(reader.id))
      refute User.disabled_on_site?(Accounts.get_user(reader.id))
    end

    test "a site disablement is shown apart from ours", %{conn: conn} do
      reader = user_fixture(%{email: "site.off@example.com"})

      assert Accounts.reconcile_site_status("557058:site.off", "site.off@example.com", :disabled) ==
               1

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#disabled-on-site-#{reader.id}")
      refute has_element?(view, "#disabled-here-#{reader.id}")
    end

    test "the button reads which flag it manages, not who blocks access", %{conn: conn} do
      reader = user_fixture(%{email: "two.flags@example.com"})
      Accounts.reconcile_site_status("557058:two.flags", "two.flags@example.com", :disabled)
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert view |> element("#toggle-#{reader.id}") |> render() =~ "Switch off here"

      view |> element("#disable-form-#{reader.id}") |> render_submit()

      assert view |> element("#toggle-#{reader.id}") |> render() =~ "Switch on here"
      assert has_element?(view, "#disabled-here-#{reader.id}")
      assert has_element?(view, "#disabled-on-site-#{reader.id}")
    end

    test "the filter narrows the list as the administrator types", %{conn: conn} do
      user_fixture(%{email: "needle@example.com"})
      user_fixture(%{email: "haystack@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> element("#user-filter") |> render_change(%{"q" => "needle"})

      assert render(view) =~ "needle@example.com"
      refute render(view) =~ "haystack@example.com"

      view |> element("#user-filter") |> render_change(%{"q" => "nothing-matches"})

      assert has_element?(view, "#accounts-empty")
    end

    test "Enter filters in place instead of submitting the page", %{conn: conn} do
      user_fixture(%{email: "needle@example.com"})
      user_fixture(%{email: "haystack@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      # The form answers `phx-submit` — without it Enter is a native submit and
      # the page reloads, filter and all.
      assert has_element?(view, "#user-filter[phx-submit=filter]")

      html = view |> element("#user-filter") |> render_submit(%{"q" => "needle"})

      assert html =~ "needle@example.com"
      refute html =~ "haystack@example.com"
    end
  end
end
