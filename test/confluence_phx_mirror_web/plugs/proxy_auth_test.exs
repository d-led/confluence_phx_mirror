defmodule ConfluencePhxMirrorWeb.Plugs.ProxyAuthTest do
  @moduledoc """
  The proxy answers "who is this?", not "should they be here?". An Atlassian
  organisation is usually wider than the site being mirrored, so the mirror
  admits an identity only when it has a reason to: an administrator, or somebody
  the sync has seen on the mirrored site.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.{Accounts, Mirror, Repo}
  alias ConfluencePhxMirror.Audit.Event

  alias ConfluencePhxMirror.Accounts.UserPolicy.{
    NewUsersCanReadPublicSpaces,
    ReadersMustExistInConfluence
  }

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :proxy_auth)
    previous_members = Application.get_env(:confluence_phx_mirror, :proxy_auth_members_only)
    previous_admin = Application.get_env(:confluence_phx_mirror, :auto_admin)

    Application.put_env(:confluence_phx_mirror, :proxy_auth, true)
    Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, true)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)

    on_exit(fn ->
      Application.put_env(:confluence_phx_mirror, :proxy_auth, previous)
      Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, previous_members)
      Application.put_env(:confluence_phx_mirror, :auto_admin, previous_admin)
    end)

    :ok
  end

  defp visit(email) do
    build_conn()
    |> put_req_header("x-forwarded-email", email)
    |> get(~p"/")
  end

  test "a member of a synced group signs in and gets an account" do
    in_group("jane@example.com", "confluence-users")

    assert html_response(visit("jane@example.com"), 200)
    assert Accounts.get_user_by_email("jane@example.com")
  end

  test "the same identity reuses the account" do
    in_group("jane@example.com", "confluence-users")

    visit("jane@example.com")
    visit("jane@example.com")

    assert [_user] = Accounts.list_users() |> Enum.filter(&(&1.email == "jane@example.com"))
  end

  test "a user named in a space permission is admitted" do
    space = space_fixture()

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "user", subject_key: "bob@example.com"}
      ])

    assert html_response(visit("bob@example.com"), 200)
    assert Accounts.get_user_by_email("bob@example.com")
  end

  test "an identity the mirrored site never mentions is refused, and no account is made" do
    conn = visit("stranger@example.com")

    assert html_response(conn, 403) =~ "not one the mirror was built for"
    refute Accounts.get_user_by_email("stranger@example.com")
  end

  test "a disabled account is refused even though the site knows it" do
    in_group("jane@example.com", "confluence-users")
    {:ok, user} = Accounts.ensure_user("jane@example.com")
    {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

    assert html_response(visit("jane@example.com"), 403)
  end

  test "a seeded administrator signing in through the proxy reaches the admin area", %{conn: conn} do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    conn = put_req_header(conn, "x-forwarded-email", "ops@example.com")

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Sync runs"
  end

  test "members-only can be switched off, so the proxy's word is enough again" do
    Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, false)

    assert html_response(visit("stranger@example.com"), 200)
    assert Accounts.get_user_by_email("stranger@example.com")
  end

  test "the header is ignored when proxy auth is off", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :proxy_auth, false)

    conn = conn |> put_req_header("x-forwarded-email", "jane@example.com") |> get(~p"/")

    assert html_response(conn, 200)
    refute Accounts.get_user_by_email("jane@example.com")
  end

  describe "the deployment's policy" do
    setup do
      previous = Application.get_env(:confluence_phx_mirror, :user_policy)
      previous_groups = Application.get_env(:confluence_phx_mirror, :proxy_auth_groups_header)

      on_exit(fn ->
        Application.put_env(:confluence_phx_mirror, :user_policy, previous)
        Application.put_env(:confluence_phx_mirror, :proxy_auth_groups_header, previous_groups)
      end)

      :ok
    end

    test "a policy that admits everybody lets a stranger in" do
      use_policy(NewUsersCanReadPublicSpaces)

      assert html_response(visit("stranger@example.com"), 200)
      assert Accounts.get_user_by_email("stranger@example.com")
    end

    test "a policy that needs the site refuses a stranger even when the proxy is not members-only" do
      Application.put_env(:confluence_phx_mirror, :proxy_auth_members_only, false)
      use_policy(ReadersMustExistInConfluence)

      assert html_response(visit("stranger@example.com"), 403)
      refute Accounts.get_user_by_email("stranger@example.com")
    end

    test "a disabled account is refused before a policy that would admit it" do
      use_policy(NewUsersCanReadPublicSpaces)
      {:ok, user} = Accounts.ensure_user("banned@example.com")
      {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})

      assert html_response(visit("banned@example.com"), 403)
    end

    test "the groups the proxy asserts are checked against the site's membership" do
      # The proxy can only say what the identity provider told it. The mirror
      # checks that claim against its own membership, so an asserted group is
      # evidence only when the site lists this person in it.
      Application.put_env(:confluence_phx_mirror, :proxy_auth_groups_header, "x-forwarded-groups")
      use_policy(ReadersMustExistInConfluence)
      in_group("sam@example.com", "confluence-users")

      admitted =
        build_conn()
        |> put_req_header("x-forwarded-email", "sam@example.com")
        |> put_req_header("x-forwarded-groups", "confluence-users,engineering")
        |> get(~p"/")

      assert html_response(admitted, 200)

      refused =
        build_conn()
        |> put_req_header("x-forwarded-email", "stranger@example.com")
        |> put_req_header("x-forwarded-groups", "confluence-users")
        |> get(~p"/")

      assert html_response(refused, 403)
    end
  end

  defp use_policy(policy) do
    Application.put_env(:confluence_phx_mirror, :user_policy, policy)
  end

  # Signing in is what an operator looks for on the users screen and in the log
  # ("did this person ever come in?"), so a proxy visit has to record itself the
  # way a magic link does.
  describe "a visit behind the proxy" do
    test "is recorded once, with the account's last-seen and a log entry" do
      in_group("jane@example.com", "confluence-users")

      visit("jane@example.com")

      user = Accounts.get_user_by_email("jane@example.com")
      assert user.last_sign_in_at
      assert sign_ins(user) == 1
    end

    test "is one visit, not one per page" do
      in_group("jane@example.com", "confluence-users")

      conn = visit("jane@example.com")
      conn |> recycle() |> get(~p"/spaces")
      conn |> recycle() |> get(~p"/recent")

      assert sign_ins(Accounts.get_user_by_email("jane@example.com")) == 1
    end

    # A scripted reader sends the header and keeps no cookie, so every request
    # looks like a new session to it. The log must not grow one entry per page
    # because of that.
    test "is one visit per half hour even without a cookie" do
      in_group("jane@example.com", "confluence-users")

      visit("jane@example.com")
      visit("jane@example.com")
      visit("jane@example.com")

      assert sign_ins(Accounts.get_user_by_email("jane@example.com")) == 1
    end
  end

  defp sign_ins(user) do
    import Ecto.Query

    Repo.aggregate(
      from(e in Event,
        where: e.action == "user.signed_in" and e.entity_id == ^to_string(user.id)
      ),
      :count
    )
  end

  defp in_group(email, group) do
    {:ok, _} = Mirror.replace_group_members(group, [%{email: email, display_name: "Jane"}])
  end
end
