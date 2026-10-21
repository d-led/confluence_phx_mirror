defmodule ConfluencePhxMirror.Notifications.Subscription do
  @moduledoc """
  A user watching a space or a page.

  `frequency` is `"instant"` (one e-mail per sync that changes the watched
  content) or `"daily"` (rolled up by the digest worker).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @target_types ~w(space page)
  @frequencies ~w(instant daily)

  schema "subscriptions" do
    field :target_type, :string
    field :target_id, :integer
    field :frequency, :string, default: "instant"

    belongs_to :user, ConfluencePhxMirror.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :target_type, :target_id, :frequency])
    |> validate_required([:user_id, :target_type, :target_id, :frequency])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:frequency, @frequencies)
    |> unique_constraint([:user_id, :target_type, :target_id])
  end

  @doc "Audit entry for a user starting to watch a page or a space."
  def audit_event_created(%__MODULE__{} = subscription, user) do
    Entry.new("subscription.created", subscription.target_type, subscription.target_id, %{
      user: user.email,
      frequency: subscription.frequency
    })
  end

  @doc "Audit entry for a user watching one less page or space."
  def audit_event_deleted(user, target_type, target_id) do
    Entry.new("subscription.deleted", target_type, target_id, %{user: user.email})
  end
end
