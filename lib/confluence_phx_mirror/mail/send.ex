defmodule ConfluencePhxMirror.Mail.Send do
  @moduledoc """
  One message handed to the provider, as the provider counts it.

  The row is written *before* the message is sent, because the question it
  answers — "is there room left today?" — has to be answered before, not after.
  It is then marked `sent` or `failed`, so the day's ledger says what the
  provider was asked for and what came of it.
  """

  use Ecto.Schema

  schema "mail_sends" do
    field :dedup_key, :string
    field :day, :date
    field :state, :string, default: "pending"
    field :error, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
