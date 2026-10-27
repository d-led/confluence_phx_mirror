defmodule ConfluencePhxMirrorWeb.Plugs.ApiAuthTest do
  @moduledoc """
  What the read-only API accepts as credentials: a bearer token, or the
  `email:token` pair Confluence's own clients send as HTTP basic.

  A header the plug cannot read is *no* credentials, which is a rejection once
  the deployment stops assuming an administrator.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirrorWeb.Plugs.ApiAuth

  setup do
    user = user_fixture(%{email: "api-reader@example.com"})
    {:ok, token, _record} = Accounts.create_api_token(user, "test", {:system, "test"})

    %{user: user, token: token}
  end

  test "a bearer token is the reader it belongs to", %{user: user, token: token} do
    conn = authenticate("Bearer #{token}")

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
  end

  test "basic auth carries the reader and the token separately", %{user: user, token: token} do
    conn = authenticate(basic(user.email, token))

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
  end

  test "a basic header that is not base64 is no credentials" do
    assert_asks_for_a_token(authenticate("Basic not base64!"))
  end

  test "a basic header with no colon in it is no credentials" do
    assert_asks_for_a_token(authenticate("Basic " <> Base.encode64("only-a-token")))
  end

  test "no header at all asks for a token" do
    assert_asks_for_a_token(authenticate(nil))
  end

  test "a token nobody issued is invalid rather than missing", %{user: user} do
    conn = authenticate(basic(user.email, "nope"))

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "invalid_token"
  end

  defp authenticate(header) do
    conn = build_conn()
    conn = if header, do: put_req_header(conn, "authorization", header), else: conn
    ApiAuth.call(conn, ApiAuth.init([]))
  end

  defp basic(email, token), do: "Basic " <> Base.encode64("#{email}:#{token}")

  defp assert_asks_for_a_token(conn) do
    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "Provide an API token"
  end
end
