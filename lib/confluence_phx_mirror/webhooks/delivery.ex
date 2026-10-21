defmodule ConfluencePhxMirror.Webhooks.Delivery do
  @moduledoc """
  Every webhook delivery is stored, valid or not, so that a rejected or failed
  event can be inspected and replayed.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
end
