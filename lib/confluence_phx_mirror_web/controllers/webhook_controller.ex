defmodule ConfluencePhxMirrorWeb.WebhookController do
  @moduledoc """
  Receives Confluence webhook deliveries.

  The route is metered before it gets here, so a flood never reaches this code;
  a body larger than a delivery should be is refused before it is stored.

  An operator can switch the intake off altogether (`CM_WEBHOOK_ENABLED`), and
  then it does not answer as a switched-off intake: a reply that said so would
  advertise that the endpoint exists. Every delivery is answered exactly like a
  path nobody routed, and nothing is stored.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Webhooks

  # A delivery describes one page; a megabyte leaves room for a large body twice
  # over and keeps an open intake from parking arbitrary data in the table.
  @max_body_bytes 1_048_576

  def create(conn, params) do
    raw_body = conn.assigns[:raw_body] || ""

    if byte_size(raw_body) > @max_body_bytes,
      do: too_large(conn),
      else: receive_delivery(conn, params, raw_body)
  end

  defp receive_delivery(conn, params, raw_body) do
    token_authenticated = conn.assigns[:webhook_token_valid] == true

    case Webhooks.receive(params, raw_body, conn.req_headers,
           token_authenticated: token_authenticated
         ) do
      {:ok, delivery} ->
        conn
        |> put_status(202)
        |> json(%{status: "accepted", delivery_id: delivery.id, state: delivery.status})

      {:error, :disabled} ->
        not_routed(conn)

      {:error, :invalid_signature} ->
        conn |> put_status(401) |> json(%{error: "invalid_signature"})

      {:error, :not_configured} ->
        conn |> put_status(503) |> json(%{error: "webhook_secret_not_configured"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  defp too_large(conn) do
    conn
    |> put_status(413)
    |> json(%{error: "payload_too_large", max_bytes: @max_body_bytes})
  end

  # A path that answers "this endpoint is switched off" tells an anonymous
  # caller that the endpoint exists. `NoRouteError` is what the router raises
  # for a path nobody routed, and the endpoint renders it through `ErrorJSON`,
  # so the answer is byte-identical to anything else that is not here.
  defp not_routed(conn) do
    raise Phoenix.Router.NoRouteError, conn: conn, router: ConfluencePhxMirrorWeb.Router
  end
end
