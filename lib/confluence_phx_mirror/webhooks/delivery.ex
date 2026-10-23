defmodule ConfluencePhxMirror.Webhooks.Delivery do
  @moduledoc """
  Every webhook delivery is stored, valid or not, so that a rejected or failed
  event can be inspected and its payload sent again; the mirror has no replay
  of its own.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @type t :: %__MODULE__{}

  schema "webhook_deliveries" do
    field :event_type, :string
    field :payload, :map, default: %{}
    field :signature_valid, :boolean, default: false
    field :status, :string, default: "received"
    field :error, :string
    field :received_at, :utc_datetime
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :event_type,
      :payload,
      :signature_valid,
      :status,
      :error,
      :received_at,
      :processed_at
    ])
    |> validate_required([:payload, :received_at])
  end

  @doc "Audit entry for a delivery rejected before it was processed."
  def audit_event_rejected(%__MODULE__{} = delivery, reason) do
    webhook_entry("webhook.rejected", delivery, %{reason: reason})
  end

  @doc "Audit entry for a delivery whose event the mirror does not act on."
  def audit_event_ignored(%__MODULE__{} = delivery, event, details \\ %{}) do
    webhook_entry("webhook.ignored", delivery, Map.put(details, :event, event))
  end

  @doc "Audit entry for a delivery that enqueued a sync of `target`."
  def audit_event_queued(%__MODULE__{} = delivery, event, job_id, target) do
    webhook_entry("webhook.queued", delivery, Map.merge(target, %{event: event, job: job_id}))
  end

  @doc "Audit entry for a delivery that made the mirror delete a page."
  def audit_event_page_deleted(%__MODULE__{} = delivery, page_id, event) do
    webhook_entry("page.deleted", delivery, %{page: page_id, event: event})
  end

  defp webhook_entry(action, delivery, metadata) do
    Entry.new(action, "webhook_delivery", delivery.id, metadata)
  end
end
