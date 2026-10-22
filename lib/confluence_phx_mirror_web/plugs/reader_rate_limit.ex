defmodule ConfluencePhxMirrorWeb.Plugs.ReaderRateLimit do
  @moduledoc """
  Protects the mirror's own resources with a per-reader token window.

  Limits are configured per scope (`html`, `api`, `attachments`) under
  `:reader_rate_limit` and can be disabled entirely. Responses carry
  `X-RateLimit-*` headers; a rejected request gets `429` and `Retry-After`.
  """

  import Plug.Conn

  import Phoenix.Controller, only: [put_view: 2, render: 3]

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
        |> reject(scope, retry_after)
        |> halt()
    end
  end

  defp reject(conn, :api, _retry_after) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(429, JSON.encode!(%{error: "rate_limited", message: "Too many requests."}))
  end

  defp reject(conn, :html, retry_after) do
    conn
    |> put_status(429)
    |> put_view(ConfluencePhxMirrorWeb.ErrorHTML)
    |> render(:"429", %{retry_after: retry_after, theme: conn.assigns[:theme]})
  end

  defp reject(conn, _scope, retry_after) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "Too many requests. Please slow down (#{retry_after}s).\n")
  end

  # A signed-in reader is limited by identity. Anonymous readers are limited by
  # address — but behind a reverse proxy or a load balancer that address is the
  # proxy's, so every reader would share one bucket unless the proxy headers are
  # trusted. `CM_TRUST_PROXY_HEADERS=true` opts into that, for deployments that
  # terminate TLS in front of the mirror (see docs/configuration.md).
  defp key(conn, scope) do
    case conn.assigns[:current_user] do
      %{id: id} -> "#{scope}:user:#{id}"
      _ -> "#{scope}:ip:#{client_ip(conn)}"
    end
  end

  defp client_ip(conn) do
    if Application.get_env(:confluence_phx_mirror, :trust_proxy_headers, false) do
      forwarded_ip(conn) || peer_ip(conn)
    else
      peer_ip(conn)
    end
  end

  # Each proxy appends the address it observed, so the *last* entry is the one
  # hop a caller cannot write: the connection our trusted proxy accepted. The
  # first entry is whatever the caller chose to send, and keying on it would
  # hand out a fresh bucket for every made-up address.
  defp forwarded_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _rest] ->
        forwarded |> String.split(",") |> List.last() |> String.trim() |> blank_to_nil()

      [] ->
        nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp peer_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
