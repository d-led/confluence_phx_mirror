defmodule ConfluencePhxMirrorWeb.AuthMatrixTest do
  @moduledoc """
  Settings × identity × door, asserted together.

  The neighbouring files pin one layer each — `ProxyAuth` the plug, `UserPolicy`
  the policy, `Authorization` the permissions. A deployment runs the
  *combination*, so this file says what that combination does: which switch wins
  when two are set, that a named policy replaces the switches behind it, that a
  disabled account outranks every policy, and that being admitted is not being
  allowed to read.

  `docs/routes-auth.md` describes the layers these tests walk through.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.UserPolicy

  alias ConfluencePhxMirror.Accounts.UserPolicy.{
    NewUsersCanReadPublicSpaces,
    ReadersMustExistInConfluence
  }

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.TestConfig

  @settings [
    :proxy_auth,
    :proxy_auth_members_only,
    :self_signup,
    :user_policy,
    :auto_admin,
    :admins,
    :admin_groups
  ]

  setup do
    # The arrangement a mirroring deployment starts from: the proxy is the door
    # and admits site members, self sign-up is closed, no policy is named.
    configure(
      proxy_auth: true,
      proxy_auth_members_only: true,
      self_signup: false,
      auto_admin: false
    )

    :ok
  end

  describe "the switch in front of the policy" do
    test "with the proxy switched off, its header is not an identity" do
      configure(proxy_auth: false)

      assert html_response(visit("stranger@example.com"), 200)
      refute Accounts.get_user_by_email("stranger@example.com")
    end

    test "with it on, the same header becomes an account under allow_all" do
      configure(user_policy: NewUsersCanReadPublicSpaces)

      assert html_response(visit("stranger@example.com"), 200)
      assert Accounts.get_user_by_email("stranger@example.com")
    end
  end

  describe "a named policy replaces the switches behind it" do
    test "allow_all admits where the proxy switch says members only" do
      configure(user_policy: NewUsersCanReadPublicSpaces, proxy_auth_members_only: true)

      assert html_response(visit("stranger@example.com"), 200)
    end

    test "members_only refuses where self sign-up is open" do
      configure(user_policy: ReadersMustExistInConfluence, self_signup: true)

      refute UserPolicy.allows?(%{email: "stranger@example.com"}, :sign_in)
    end

    test "without a named policy the switches decide their own door" do
      refute UserPolicy.allows?(%{email: "stranger@example.com"}, :sign_in)
      assert html_response(visit("stranger@example.com"), 403)

      configure(self_signup: true)

      assert UserPolicy.allows?(%{email: "stranger@example.com"}, :sign_in)
    end
  end

  describe "identities the policy admits for a reason of their own" do
    test "a seeded administrator gets in where the site never names them" do
      configure(admins: ["boss@example.com"])

      assert html_response(visit("boss@example.com"), 200)
    end

    test "a mirror administrator does too" do
      admin = user_fixture(%{email: "admin@example.com", role: "admin"})

      assert html_response(visit(admin.email), 200)
    end
  end

  describe "a disabled account" do
    test "is refused at the proxy door even where the policy admits everybody" do
      user = user_fixture(%{email: "banned@example.com"})
      {:ok, _} = Accounts.set_disabled(user, true, {:system, "test"})
      configure(user_policy: NewUsersCanReadPublicSpaces)

      assert html_response(visit(user.email), 403)
    end
  end

  describe "admission is not authorization" do
    test "a reader admitted by allow_all still cannot open a restricted page" do
      demo_snapshot!()
      configure(user_policy: NewUsersCanReadPublicSpaces)

      assert html_response(visit("curious@example.com"), 200)
      assert response(visit("curious@example.com", "/spaces/ENG/pages/1003"), 404)
    end
  end

  describe "administration" do
    test "a group the deployment names grants it without a role" do
      configure(admin_groups: ["site-admins"])
      user = user_fixture(%{email: "curator@example.com"})

      assert {:error, {:redirect, %{to: "/"}}} = signed_in(user) |> live(~p"/admin/settings")

      {:ok, _} =
        Mirror.replace_group_members("site-admins", [
          %{email: user.email, display_name: "Curator"}
        ])

      assert {:ok, _view, _html} = signed_in(user) |> live(~p"/admin/settings")
    end

    test "nothing grants it when no source names the reader" do
      user = user_fixture(%{email: "reader@example.com"})

      assert {:error, {:redirect, %{to: "/"}}} = signed_in(user) |> live(~p"/admin/settings")
    end
  end

  describe "the API door" do
    test "refuses an anonymous caller, unlike the pages" do
      assert build_conn() |> get(~p"/api/v1/stats") |> response(401)
    end

    test "refuses a token issued for another scope" do
      {:ok, token, _token} =
        Accounts.create_service_token("webhook-client", "webhook", {:system, "test"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/stats")

      assert response(conn, 401)
    end
  end

  defp configure(pairs) do
    Enum.each(pairs, fn {key, value} -> TestConfig.put(key, value) end)
  end

  # The proxy's side of the arrangement: an identity arrives as a header.
  defp visit(email, path \\ ~p"/") do
    build_conn() |> put_req_header("x-forwarded-email", email) |> get(path)
  end

  defp signed_in(user), do: build_conn() |> init_test_session(user_id: user.id)
end
