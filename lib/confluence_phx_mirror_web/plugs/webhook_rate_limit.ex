defmodule ConfluencePhxMirrorWeb.Plugs.WebhookRateLimit do
  @moduledoc """
  Caps webhook deliveries per client address.

  A delivery is stored before its signature is checked, on purpose: a rejected
  or malformed event stays auditable and replayable. That also makes the route
  somewhere an unauthenticated caller can write rows, so it is the one intake
  that is always metered — independently of `:reader_rate_limit`, which a
  deployment may switch off for its readers.

  Over the cap the request is refused before anything is stored; the deliveries
  that were accepted keep their audit trail.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.RateLimit

  @default_limit 60
  @default_period_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    {limit, period_ms} = config()

    case RateLimit.hit("webhook:#{client_ip(conn)}", period_ms, limit) do
      {:allow, _count} -> conn
      {:deny, retry_after_ms} -> reject(conn, retry_after_ms)
    end
  end

  defp config do
    settings = Application.get_env(:confluence_phx_mirror, :webhook_rate_limit, [])

    {Keyword.get(settings, :limit, @default_limit),
     Keyword.get(settings, :period_ms, @default_period_ms)}
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp reject(conn, retry_after_ms) do
    retry_after = max(div(retry_after_ms + 999, 1000), 1)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send_resp(429, JSON.encode!(%{error: "rate_limited"}))
    |> halt()
  end
end
