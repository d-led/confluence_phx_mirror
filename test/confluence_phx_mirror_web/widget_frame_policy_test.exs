defmodule ConfluencePhxMirrorWeb.WidgetFramePolicyTest do
  @moduledoc """
  A widget connector may frame a third party, and only a host an operator named.

  The renderer and the content security policy read one list (`Sync.Embeds`), so
  what this file says is that the two agree. Built separately they would drift,
  and the failure is silent in both directions: a frame the mirror drew and the
  browser refuses looks like a broken page, and a policy wider than the renderer
  is a hole nobody draws through yet.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirror.TestConfig

  test "a reader page frames nothing by default", %{conn: conn} do
    [policy] = conn |> get(~p"/") |> get_resp_header("content-security-policy")

    assert policy =~ "frame-src 'self';"
    assert policy =~ "frame-ancestors 'none'"
  end

  test "the host an operator named is the host the page may frame", %{conn: conn} do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    [policy] = conn |> get(~p"/") |> get_resp_header("content-security-policy")

    assert policy =~ "frame-src 'self' https://youtube.com https://*.youtube.com;"
  end
end
