defmodule ConfluencePhxMirror.Notifications.Notification do
  @moduledoc """
  Outbox row for an e-mail notification. Keeping the rendered message makes
  deliveries auditable and retryable.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "notifications" do
    field :kind, :string
    field :subject, :string
    field :body, :string
    field :delivered_at, :utc_datetime
    field :error, :string

    belongs_to :user, ConfluencePhxMirror.Accounts.User
    belongs_to :page, ConfluencePhxMirror.Mirror.Page

    timestamps(type: :utc_datetime)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :page_id, :kind, :subject, :body, :delivered_at, :error])
    |> validate_required([:user_id, :kind, :subject, :body])
  end
end
