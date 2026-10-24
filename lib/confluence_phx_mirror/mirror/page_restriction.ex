defmodule ConfluencePhxMirror.Mirror.PageRestriction do
  @moduledoc """
  A read restriction on one page, as Confluence stores it: the users and groups
  allowed to read the page. A page without rows is unrestricted, which is the
  common case — space permissions decide there.

  A row with `granted_by_id` set is the mirror's own: an administrator let one
  more reader onto a page the site restricted. The sync replaces only the rows it
  wrote, so a grant survives every run.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @subject_types ~w(user group)
  @operations ~w(read)

  schema "page_restrictions" do
    field :operation, :string, default: "read"
    field :subject_type, :string
    field :subject_key, :string

    belongs_to :page, ConfluencePhxMirror.Mirror.Page
    belongs_to :granted_by, ConfluencePhxMirror.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @fields [:page_id, :operation, :subject_type, :subject_key, :granted_by_id]

  def changeset(restriction, attrs) do
    restriction
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:operation, @operations)
    |> unique_constraint([:page_id, :operation, :subject_type, :subject_key],
      name: :page_restrictions_unique
    )
  end

  @doc "Audit entry for a reader this mirror let onto a restricted page."
  def audit_event_granted(%__MODULE__{} = row, page_title) do
    ConfluencePhxMirror.Audit.Entry.new("page.access_granted", "page", page_title, %{
      subject_type: row.subject_type,
      subject: row.subject_key
    })
  end

  @doc "Audit entry for taking that reader away again."
  def audit_event_revoked(%__MODULE__{} = row, page_title) do
    ConfluencePhxMirror.Audit.Entry.new("page.access_revoked", "page", page_title, %{
      subject_type: row.subject_type,
      subject: row.subject_key
    })
  end
end
