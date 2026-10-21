defmodule ConfluencePhxMirror.Webhooks do
  @moduledoc """
  Incoming Confluence webhooks.

  Every delivery is stored before anything else happens, so a rejected or
  malformed event can be audited and replayed. Signatures are verified over the
  raw request body with HMAC-SHA256 (`X-Hub-Signature-256`, or the legacy
  `X-Hub-Signature`).

  Accepted events are turned into incremental work: page, blog post and
  attachment events re-sync the affected page; comment events re-sync the
  page that hosts the comment; space events queue a space sync. Removal events
  mark the page deleted immediately.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.{Audit, Mirror, Repo}
  alias ConfluencePhxMirror.Sync.{PageWorker, SpaceWorker}
  alias ConfluencePhxMirror.Webhooks.Delivery

  @removal_events ~w(page_removed page_trashed page_deleted content_deleted blogpost_removed)

  @page_events ~w(page_created page_updated page_restored page_moved
                  blogpost_created blogpost_updated
                  attachment_created attachment_updated attachment_deleted attachment_trashed
                  comment_created comment_updated comment_removed comment_replied)

  @space_events ~w(space_created space_updated)

  @type outcome :: {:ok, Delivery.t()} | {:error, :invalid_signature | :not_configured | term()}

  @doc """
  Processes one delivery.

  `payload` is the decoded JSON, `raw_body` the exact request body and
  `headers` the request headers (a list of `{name, value}` tuples).
  """
  @spec receive(map(), binary(), [{String.t(), String.t()}]) :: outcome()
  def receive(payload, raw_body, headers) do
    secret = config()[:secret]
    signature = signature_header(headers)

    signature_valid =
      cond do
        is_nil(secret) -> false
        is_nil(signature) -> false
        true -> verify(raw_body, signature, secret)
      end

    delivery = store_delivery(payload, signature_valid, secret)

    cond do
      is_nil(secret) and config()[:require_signature] ->
        finish(delivery, "rejected", "webhook secret is not configured")
        Audit.log(actor(delivery), Delivery.audit_event_rejected(delivery, "not_configured"))
        {:error, :not_configured}

      not signature_valid ->
        finish(delivery, "rejected", "signature mismatch")
        Audit.log(actor(delivery), Delivery.audit_event_rejected(delivery, "invalid_signature"))
        {:error, :invalid_signature}

      true ->
        handle(delivery)
    end
  end

  @doc "Constant-time HMAC-SHA256 verification of a raw body."
  def verify(raw_body, signature, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

    received =
      signature |> String.trim() |> String.replace_prefix("sha256=", "") |> String.downcase()

    byte_size(expected) == byte_size(received) and Plug.Crypto.secure_compare(expected, received)
  end

  @doc "Event name of a Confluence webhook payload."
  def event_type(payload) do
    payload["event"] || payload["eventType"] || payload["event_type"]
  end

  @doc "Page id affected by a webhook payload, for page, comment and attachment events."
  def page_id(payload) do
    candidates = [
      get_in(payload, ["page", "id"]),
      get_in(payload, ["blogpost", "id"]),
      get_in(payload, ["content", "id"]),
      get_in(payload, ["attachment", "container", "id"]),
      get_in(payload, ["attachment", "containerId"]),
      get_in(payload, ["comment", "container", "id"]),
      payload["pageId"],
      payload["contentId"]
    ]

    Enum.find_value(candidates, &normalise_id/1)
  end

  @doc "Space key affected by a space webhook payload."
  def space_key(payload) do
    get_in(payload, ["space", "key"]) || payload["spaceKey"]
  end

  defp normalise_id(nil), do: nil
  defp normalise_id(id) when is_integer(id), do: id

  defp normalise_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp actor(delivery), do: {:webhook, delivery.id}

  defp handle(delivery) do
    event = event_type(delivery.payload)

    if event in @space_events do
      enqueue_space(delivery, event)
    else
      handle_page_event(delivery, event, page_id(delivery.payload))
    end
  end

  defp handle_page_event(delivery, event, id) do
    cond do
      is_nil(id) ->
        finish(delivery, "ignored", nil)
        Audit.log(actor(delivery), Delivery.audit_event_ignored(delivery, event))
        {:ok, Repo.get!(Delivery, delivery.id)}

      event in @removal_events ->
        mark_deleted(delivery, id, event)

      event in @page_events or is_nil(event) ->
        enqueue_page(delivery, id, event)

      true ->
        finish(delivery, "ignored", nil)
        Audit.log(actor(delivery), Delivery.audit_event_ignored(delivery, event))
        {:ok, Repo.get!(Delivery, delivery.id)}
    end
  end

  defp mark_deleted(delivery, id, event) do
    case Mirror.mark_deleted(id) do
      {:ok, _page} ->
        Audit.log(actor(delivery), Delivery.audit_event_page_deleted(delivery, id, event))
        finish(delivery, "processed", nil)
        {:ok, Repo.get!(Delivery, delivery.id)}

      {:error, :not_found} ->
        finish(delivery, "ignored", "page not in mirror")
        Audit.log(actor(delivery), Delivery.audit_event_ignored(delivery, event, %{page: id}))
        {:ok, Repo.get!(Delivery, delivery.id)}
    end
  end

  defp enqueue_page(delivery, id, event) do
    case %{"confluence_id" => id} |> PageWorker.new() |> Oban.insert() do
      {:ok, job} ->
        Audit.log(
          actor(delivery),
          Delivery.audit_event_queued(delivery, event, job.id, %{page: id})
        )

        finish(delivery, "queued", nil)
        {:ok, Repo.get!(Delivery, delivery.id)}

      {:error, reason} ->
        finish(delivery, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp enqueue_space(delivery, event) do
    case space_key(delivery.payload) do
      nil ->
        finish(delivery, "ignored", nil)

        Audit.log(
          actor(delivery),
          Delivery.audit_event_ignored(delivery, event, %{reason: "no space key"})
        )

        {:ok, Repo.get!(Delivery, delivery.id)}

      key ->
        case %{"space_key" => key} |> SpaceWorker.new() |> Oban.insert() do
          {:ok, job} ->
            Audit.log(
              actor(delivery),
              Delivery.audit_event_queued(delivery, event, job.id, %{space: key})
            )

            finish(delivery, "queued", nil)
            {:ok, Repo.get!(Delivery, delivery.id)}

          {:error, reason} ->
            finish(delivery, "failed", inspect(reason))
            {:error, reason}
        end
    end
  end

  defp store_delivery(payload, signature_valid, secret) do
    %Delivery{}
    |> Delivery.changeset(%{
      event_type: event_type(payload),
      payload: payload,
      signature_valid: signature_valid,
      status: if(secret, do: "processing", else: "received"),
      received_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp finish(delivery, status, error) do
    delivery
    |> Ecto.Changeset.change(
      status: status,
      error: error,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  defp signature_header(headers) do
    Enum.find_value(
      ~w(x-hub-signature-256 x-hub-signature x-atlassian-webhook-signature),
      fn name ->
        Enum.find_value(headers, fn {header_name, value} ->
          if String.downcase(header_name) == name, do: value
        end)
      end
    )
  end

  @doc "Recent deliveries for the admin view."
  def recent(limit \\ 50) do
    Repo.all(from d in Delivery, order_by: [desc: d.received_at], limit: ^limit)
  end

  @doc "Pages touched by webhooks that are not in the mirror yet (diagnostics)."
  def unknown_pages do
    Repo.all(
      from d in Delivery,
        where: d.status == "ignored",
        order_by: [desc: d.received_at],
        limit: 20,
        select: %{event: d.event_type, payload: d.payload, received_at: d.received_at}
    )
  end

  defp config, do: Application.get_env(:confluence_phx_mirror, :webhooks, [])
end
