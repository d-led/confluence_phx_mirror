defmodule Mix.Tasks.Confluence.Webhook do
  @shortdoc "Sends a signed test webhook to the mirror"

  @moduledoc """
  Sends a properly signed webhook, useful to demo the webhook path without
  configuring Confluence. The secret must match `CM_WEBHOOK_SECRET`.

      mix confluence.webhook --page 1002 --event page_updated
      mix confluence.webhook --page 1002 --event page_removed

  The mirror is read-only: the event only tells the mirror to re-read that page
  from the source, exactly as Confluence would.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          page: :integer,
          event: :string,
          url: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    page_id = Keyword.get(opts, :page) || Mix.raise("--page is required")
    event = Keyword.get(opts, :event, "page_updated")
    url = Keyword.get(opts, :url) || default_url()

    secret =
      System.get_env("CM_WEBHOOK_SECRET") ||
        if Mix.env() == :dev do
          "dev-webhook-secret"
        else
          Mix.raise("Set CM_WEBHOOK_SECRET to the value the mirror was started with.")
        end

    payload = %{
      "event" => event,
      "page" => %{"id" => to_string(page_id)},
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    body = JSON.encode!(payload)

    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    case Req.post(url,
           body: body,
           headers: [
             {"content-type", "application/json"},
             {"x-hub-signature-256", signature}
           ],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: response}} ->
        Mix.shell().info("HTTP #{status}: #{inspect(response)}")

        unless status in 200..299 do
          exit({:shutdown, 1})
        end

      {:error, reason} ->
        Mix.raise("Webhook request failed: #{inspect(reason)}")
    end
  end

  defp default_url do
    ConfluencePhxMirrorWeb.Endpoint.url() <> "/webhooks/confluence"
  end
end
