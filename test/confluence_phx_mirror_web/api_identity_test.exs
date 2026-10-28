defmodule ConfluencePhxMirrorWeb.ApiIdentityTest do
  @moduledoc """
  The JSON API accepts the identity the browser already carries.

  Behind oauth2-proxy the browser is authenticated by a cookie the proxy reads
  and forwards as `X-Forwarded-Email`; the mirror's own magic-link session says
  the same thing. Either is enough for a read-only API, which is what lets
  `/api/docs/swagger` answer *Try it out* as the reader who opened it. A token
  remains for scripts, and an anonymous request outside the demo is still 401 —
  accepting a cookie must not turn the API into a public endpoint.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.UserPolicy.NewUsersCanReadPublicSpaces
  alias ConfluencePhxMirror.TestConfig

  @settings [:proxy_auth, :proxy_auth_members_only, :self_signup, :auto_admin, :user_policy]

  setup do
    # A mirroring deployment: the proxy is the door, nobody is assumed, and an
    # arriving identity gets an account.
    configure(
      proxy_auth: true,
      proxy_auth_members_only: false,
      self_signup: false,
      auto_admin: false,
      user_policy: NewUsersCanReadPublicSpaces
    )

    :ok
  end

  test "the identity the proxy established is the caller", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-forwarded-email", "reader@example.com")
      |> get(~p"/api/v1/spaces")

    assert %{"results" => results} = json_response(conn, 200)
    assert is_list(results)
  end

  test "a signed-in browser session is the caller too", %{conn: conn} do
    user = user_fixture()

    conn = conn |> init_test_session(user_id: user.id) |> get(~p"/api/v1/spaces")

    assert %{"results" => results} = json_response(conn, 200)
    assert is_list(results)
  end

  test "with neither, the API still refuses an anonymous request", %{conn: conn} do
    assert %{"error" => "unauthorized"} = conn |> get(~p"/api/v1/spaces") |> json_response(401)
  end

  test "a proxy that is switched off is not an identity", %{conn: conn} do
    configure(proxy_auth: false)

    conn =
      conn
      |> put_req_header("x-forwarded-email", "reader@example.com")
      |> get(~p"/api/v1/spaces")

    assert json_response(conn, 401)
  end

  test "a disabled account is refused even with a valid session", %{conn: conn} do
    user = user_fixture()
    {:ok, _} = ConfluencePhxMirror.Accounts.set_disabled(user, true, {:system, "test"})

    conn = conn |> init_test_session(user_id: user.id) |> get(~p"/api/v1/spaces")

    assert json_response(conn, 401)
  end

  defp configure(pairs) do
    Enum.each(pairs, fn {key, value} -> TestConfig.put(key, value) end)
  end
end
