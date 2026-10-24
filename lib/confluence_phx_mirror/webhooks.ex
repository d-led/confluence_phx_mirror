defmodule ConfluencePhxMirror.Webhooks do
  @moduledoc """
  Incoming Confluence webhooks.

  Every delivery is stored before anything else happens, so a rejected or
  malformed event can be audited and its payload posted again by hand. The
  mirror itself does not replay deliveries. Signatures are verified over the
  raw request body with HMAC-SHA256 (`X-Hub-Signature-256`, or the legacy
  `X-Hub-Signature`).

  A delivery may also present a route token instead; and a deployment that
  cannot authenticate its sender at all may accept unsigned deliveries. That is
  the default, because a mirror that has just been pointed at a Confluence site
  should work, and it is what `/admin/webhooks` warns about until somebody
  requires authentication (`CM_WEBHOOK_REQUIRE_SIGNATURE`, or the same switch
  from that page, which takes effect without a restart).

  Accepted events are turned into incremental work: page, blog post and
  attachment events re-sync the affected page; comment events re-sync the
  page that hosts the comment; space events queue a space sync. Removal events
  mark the page deleted immediately.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.{Audit, Mirror, Repo, Settings}
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

  Options:

    * `:token_authenticated` – the route-level token plug already verified the
      sender, so a signature is not required
  """
  @spec receive(map(), binary(), [{String.t(), String.t()}], keyword()) :: outcome()
  def receive(payload, raw_body, headers, opts \\ []) do
    if enabled?() do
      accept(payload, raw_body, headers, opts)
    else
      # Nothing is stored: a disabled intake is not a delivery log, and keeping
      # the payloads of a route an operator switched off would be a surprise.
      {:error, :disabled}
    end
  end

  @doc """
  Whether the intake accepts deliveries at all.

  Off means every delivery is refused with `410 Gone` and nothing is stored.
  It is the switch for a mirror that has no reason to be reachable by the site —
  one behind a sign-in proxy, or whose sync is scheduled — and it is separate
  from `require_signature`, which decides who may post rather than whether
  anyone may.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.webhook_enabled?() do
      nil -> Keyword.get(config(), :enabled, true)
      value -> value
    end
  end

  defp accept(payload, raw_body, headers, opts) do
    secret = config()[:secret]

    case authenticate(raw_body, signature_header(headers), secret, opts) do
      {:ok, authenticated?} ->
        payload |> store_delivery(authenticated?, secret) |> handle()

      {:error, reason} ->
        payload |> store_delivery(false, secret) |> reject(reason)
    end
  end

  @doc """
  Whether a delivery has to be authenticated.

  The deployment decides (`CM_WEBHOOK_REQUIRE_SIGNATURE`, or
  `config :confluence_phx_mirror, :webhooks`), and an administrator's decision
  on `/admin/webhooks` overrides it without a restart. The default is *not* to
  require one: a mirror pointed at a Confluence site keeps working, and the
  admin page says what that costs until somebody closes it.
  """
  @spec signature_required?() :: boolean()
  def signature_required? do
    case Settings.webhook_require_signature() do
      nil -> Keyword.get(config(), :require_signature, false)
      required? -> required?
    end
  end

  # A valid HMAC over the raw body, a route or service token — or, when this
  # deployment says a signature is not required, no credential at all. A
  # signature that *is* presented always has to be good: a delivery pretending
  # to be authenticated is worse than one that claims nothing.
  defp authenticate(raw_body, signature, secret, opts) do
    cond do
      Keyword.get(opts, :token_authenticated, false) ->
        {:ok, true}

      is_binary(signature) ->
        if signed?(raw_body, signature, secret),
          do: {:ok, true},
          else: {:error, failure(secret)}

      signature_required?() ->
        {:error, failure(secret)}

      true ->
        {:ok, false}
    end
  end

  defp signed?(raw_body, signature, secret) do
    is_binary(secret) and is_binary(signature) and verify(raw_body, signature, secret)
  end

  defp failure(secret), do: if(is_nil(secret), do: :not_configured, else: :invalid_signature)

  defp reject(delivery, reason) do
    finish(delivery, "rejected", rejection_message(reason))
    Audit.log(actor(delivery), Delivery.audit_event_rejected(delivery, Atom.to_string(reason)))
    {:error, reason}
  end

  defp rejection_message(:not_configured), do: "webhook secret is not configured"
  defp rejection_message(:invalid_signature), do: "signature mismatch"

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

  @doc "Space key affected by a space webhook payload, or nil when it is not one."
  def space_key(payload) do
    case get_in(payload, ["space", "key"]) || payload["spaceKey"] do
      key when is_binary(key) and byte_size(key) <= 255 ->
        if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, key), do: key

      _other ->
        nil
    end
  end

  # A page id is a whole number and nothing else: `"1002abc"` is not a page, and
  # `0` or a negative is not one either. Anything the mirror cannot recognise is
  # ignored rather than passed to a worker that would fail five times over it.
  defp normalise_id(id) when is_integer(id) and id > 0, do: id

  defp normalise_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp normalise_id(_id), do: nil

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
    args = %{"confluence_id" => id, "trigger" => "the #{event} webhook"}

    case args |> PageWorker.new() |> Oban.insert() do
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
        args = %{"space_key" => key, "trigger" => "the #{event} webhook"}

        case args |> SpaceWorker.new() |> Oban.insert() do
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
