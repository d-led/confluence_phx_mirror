defmodule ConfluencePhxMirrorWeb.Plugs.WebhookAuth do
  @moduledoc """
  Route-level token authentication for webhook receivers.

  Some senders cannot compute an HMAC and instead put a fixed token in the URL
  or a header. That token must not open anything else in the mirror, so this
  plug lives on the webhook pipeline only and is configured per receiver:

      config :confluence_phx_mirror, :webhook_tokens, %{"confluence" => "s3cret"}

  A request authenticates by presenting the token as `Authorization: Bearer`,
  `X-Webhook-Token`, or `?token=`. Without a configured token the plug does
  nothing and the HMAC signature remains the only check; a configured receiver
  accepts either the token or a valid signature.

  Service tokens issued in *Users & tokens* also work here: they have no user
  and carry the `webhook` scope, so they cannot open the API or the reader UI.
  """

  import Plug.Conn

  alias ConfluencePhxMirror.Accounts

  def init(opts), do: opts

  def call(conn, opts) do
    token = token_for(Keyword.get(opts, :receiver, "confluence"))
    presented = presented(conn)

    cond do
      authenticated?(presented, token) -> assign(conn, :webhook_token_valid, true)
      is_nil(token) -> conn
      true -> reject(conn)
    end
  end

  defp token_for(receiver) do
    case Application.get_env(:confluence_phx_mirror, :webhook_tokens, %{}) do
      %{^receiver => token} when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp authenticated?(nil, _token), do: false

  defp authenticated?(presented, token) do
    matches_config?(presented, token) or service_token?(presented)
  end

  defp matches_config?(_presented, nil), do: false

  defp matches_config?(presented, token) do
    byte_size(presented) == byte_size(token) and Plug.Crypto.secure_compare(presented, token)
  end

  defp service_token?(presented) do
    match?({:ok, _}, Accounts.authenticate_service_token(presented, "webhook"))
  end

  defp presented(conn) do
    header(conn, "x-webhook-token") || bearer(conn) || conn.params["token"]
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp bearer(conn) do
    case header(conn, "authorization") do
      "Bearer " <> token -> token
      _ -> nil
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, JSON.encode!(%{error: "invalid_webhook_token"}))
    |> halt()
  end
end
