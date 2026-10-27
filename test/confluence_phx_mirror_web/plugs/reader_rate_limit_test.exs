defmodule ConfluencePhxMirrorWeb.Plugs.ReaderRateLimitTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirror.TestConfig

  defp allow_one_request_per_minute do
    TestConfig.put(
      :reader_rate_limit,
      enabled: true,
      html: [limit: 1, period_ms: 60_000],
      api: [limit: 1, period_ms: 60_000],
      attachments: [limit: 1, period_ms: 60_000]
    )
  end

  defp reader(peer_ip, forwarded_for \\ nil) do
    conn = %{build_conn() | remote_ip: peer_ip}

    if forwarded_for,
      do: put_req_header(conn, "x-forwarded-for", forwarded_for),
      else: conn
  end

  test "a throttled reader is told when to come back", %{} do
    allow_one_request_per_minute()
    peer = {198, 51, 100, 1}

    assert get(reader(peer), "/").status == 200

    throttled = get(reader(peer), "/")

    assert throttled.status == 429
    assert html_response(throttled, 429) =~ "Try again in"
    assert [retry_after] = get_resp_header(throttled, "retry-after")
    assert String.to_integer(retry_after) >= 1
  end

  test "trusted proxy headers give each reader their own bucket" do
    allow_one_request_per_minute()
    TestConfig.put(:trust_proxy_headers, true)
    peer = {198, 51, 100, 2}

    assert get(reader(peer, "203.0.113.10"), "/").status == 200
    assert get(reader(peer, "203.0.113.11"), "/").status == 200
    assert get(reader(peer, "203.0.113.10"), "/").status == 429
  end

  test "a forged entry ahead of the proxy's own record buys no fresh bucket" do
    allow_one_request_per_minute()
    TestConfig.put(:trust_proxy_headers, true)
    peer = {198, 51, 100, 4}

    assert get(reader(peer, "203.0.113.30"), "/").status == 200
    assert get(reader(peer, "10.9.9.9, 203.0.113.30"), "/").status == 429
  end

  test "proxy headers are ignored unless the deployment trusts them" do
    allow_one_request_per_minute()
    peer = {198, 51, 100, 3}

    assert get(reader(peer, "203.0.113.20"), "/").status == 200
    assert get(reader(peer, "203.0.113.21"), "/").status == 429
  end
end
