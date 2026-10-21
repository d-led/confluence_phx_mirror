defmodule ConfluencePhxMirror.Mirror.PageRestriction do
  @moduledoc """
  A read restriction on one page, as Confluence stores it: the users and groups
  allowed to read the page. A page without rows is unrestricted, which is the
  common case — space permissions decide there.
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

    timestamps(type: :utc_datetime)
  end

  @fields [:page_id, :operation, :subject_type, :subject_key]

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
end
