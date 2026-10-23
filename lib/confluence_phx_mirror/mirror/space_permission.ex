defmodule ConfluencePhxMirror.Mirror.SpacePermission do
  @moduledoc """
  Who may read a space.

  A Confluence space grants an operation to principals — people, groups, or
  anonymous readers — and these rows are that grant list as the last sync read
  it (`/space/{key}?expand=permissions` on Cloud). A space without rows is open: the
  mirror shows exactly what the sync account can read unless something narrows
  it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @subject_types ~w(user group authenticated anonymous)
  @operations ~w(read administer)

  schema "space_permissions" do
    field :operation, :string, default: "read"
    field :subject_type, :string
    field :subject_key, :string

    belongs_to :space, ConfluencePhxMirror.Mirror.Space

    timestamps(type: :utc_datetime)
  end

  @fields [:space_id, :operation, :subject_type, :subject_key]

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, @fields)
    |> validate_required([:space_id, :operation, :subject_type])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:operation, @operations)
    |> unique_constraint([:space_id, :operation, :subject_type, :subject_key],
      name: :space_permissions_unique
    )
  end
end
