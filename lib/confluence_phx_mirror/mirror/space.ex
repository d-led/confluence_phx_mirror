defmodule ConfluencePhxMirror.Mirror.Space do
  @moduledoc """
  A mirrored Confluence space.

  `key` is the Confluence space key; `homepage_confluence_id` points at the
  page that acts as the space home in the mirror.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "spaces" do
    field :key, :string
    field :name, :string
    field :type, :string, default: "global"
    field :description, :string
    field :homepage_confluence_id, :integer
    field :external_url, :string
    field :synced_at, :utc_datetime

    has_many :pages, ConfluencePhxMirror.Mirror.Page

    timestamps(type: :utc_datetime)
  end

  @required_fields [:key, :name]
  @optional_fields [:type, :description, :homepage_confluence_id, :external_url, :synced_at]

  def changeset(space, attrs) do
    space
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> update_change(:key, &String.upcase/1)
    |> validate_format(:key, ~r/^[A-Z0-9_~.-]+$/, message: "is not a valid space key")
    |> unique_constraint(:key)
  end
end
