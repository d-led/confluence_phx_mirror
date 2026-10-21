defmodule ConfluencePhxMirrorWeb.Plugs.ReaderRateLimit do
  @moduledoc """
  Protects the mirror's own resources with a per-reader token window.

  Limits are configured per scope (`html`, `api`, `attachments`) under
  `:reader_rate_limit` and can be disabled entirely. Responses carry
  `X-RateLimit-*` headers; a rejected request gets `429` and `Retry-After`.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.RateLimit

  def init(opts), do: opts

  def call(conn, opts) do
    scope = Keyword.fetch!(opts, :scope)

    case lookup(scope) do
      :disabled -> conn
      {:ok, limit, period_ms} -> enforce(conn, scope, limit, period_ms)
    end
  end

  defp lookup(scope) do
    config = Application.get_env(:confluence_phx_mirror, :reader_rate_limit, [])

    if Keyword.get(config, :enabled, false) do
      scope_config = Keyword.get(config, scope, [])
      {:ok, Keyword.get(scope_config, :limit, 120), Keyword.get(scope_config, :period_ms, 60_000)}
    else
      :disabled
    end
  end

  defp enforce(conn, scope, limit, period_ms) do
    case RateLimit.hit(key(conn, scope), period_ms, limit) do
      {:allow, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(limit - count, 0)))

      {:deny, retry_after_ms} ->
        retry_after = max(div(retry_after_ms + 999, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> reject(scope)
        |> halt()
    end
  end

  defp reject(conn, :api) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{error: "rate_limited", message: "Too many requests."}))
  end

  defp reject(conn, _scope) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "Too many requests. Please slow down.\n")
  end

  defp key(conn, scope) do
    case conn.assigns[:current_user] do
      %{id: id} -> "#{scope}:user:#{id}"
      _ -> "#{scope}:ip:#{client_ip(conn)}"
    end
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
