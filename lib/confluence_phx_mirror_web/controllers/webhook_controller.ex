defmodule ConfluencePhxMirrorWeb.WebhookController do
  @moduledoc "Receives Confluence webhook deliveries."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Webhooks

  def create(conn, params) do
    raw_body = conn.assigns[:raw_body] || ""
    token_authenticated = conn.assigns[:webhook_token_valid] == true

    case Webhooks.receive(params, raw_body, conn.req_headers,
           token_authenticated: token_authenticated
         ) do
      {:ok, delivery} ->
        conn
        |> put_status(202)
        |> json(%{status: "accepted", delivery_id: delivery.id, state: delivery.status})

      {:error, :invalid_signature} ->
        conn |> put_status(401) |> json(%{error: "invalid_signature"})

      {:error, :not_configured} ->
        conn |> put_status(503) |> json(%{error: "webhook_secret_not_configured"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end
end
