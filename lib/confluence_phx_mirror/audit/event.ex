defmodule ConfluencePhxMirror.Audit.Event do
  @moduledoc """
  Append-only audit event. `actor` is one of `"user"`, `"system"` or
  `"webhook"`; `action` is a dotted verb such as `"page.updated"` or
  `"api_token.created"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @actor_types ~w(user system webhook)

  schema "audit_events" do
    field :actor_type, :string
    field :actor_id, :string
    field :actor_label, :string
    field :action, :string
    field :entity_type, :string
    field :entity_id, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor_type,
      :actor_id,
      :actor_label,
      :action,
      :entity_type,
      :entity_id,
      :metadata,
      :inserted_at
    ])
    |> validate_required([:actor_type, :action, :inserted_at])
    |> validate_inclusion(:actor_type, @actor_types)
  end
end
