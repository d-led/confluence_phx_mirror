defmodule ConfluencePhxMirror.Mirror.SpacePermission do
  @moduledoc """
  Who may read a space.

  A Confluence space grants an operation to principals — people, groups, or
  anonymous readers — and these rows are that grant list as the last sync read
  it (`/space/{key}?expand=permissions` on Cloud). A space without rows is open: the
  mirror shows exactly what the sync account can read unless something narrows
  it.

  A row with `granted_by_id` set is the mirror's own decision rather than the
  site's: an administrator let one more reader in here. The sync replaces only
  the rows it wrote, so a grant survives every run, and every access rule reads
  the same table without learning a second concept.
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
    belongs_to :granted_by, ConfluencePhxMirror.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @fields [:space_id, :operation, :subject_type, :subject_key, :granted_by_id]

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

  @doc "Whether the mirror, not the site, granted this row."
  def granted_here?(%__MODULE__{granted_by_id: id}), do: not is_nil(id)

  @doc "Audit entry for a reader this mirror let into a narrow space."
  def audit_event_granted(%__MODULE__{} = row, space_key) do
    ConfluencePhxMirror.Audit.Entry.new("space.access_granted", "space", space_key, %{
      subject_type: row.subject_type,
      subject: row.subject_key
    })
  end

  @doc "Audit entry for taking that reader away again."
  def audit_event_revoked(%__MODULE__{} = row, space_key) do
    ConfluencePhxMirror.Audit.Entry.new("space.access_revoked", "space", space_key, %{
      subject_type: row.subject_type,
      subject: row.subject_key
    })
  end
end
