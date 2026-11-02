defmodule ConfluencePhxMirror.Desktop.Schema.Space do
  @moduledoc """
  A mirrored space.

  Not `ConfluencePhxMirror.Mirror.Space`: that one carries what a *server* needs
  — permission rows, page listings, blob digests for a shared store — and its
  array columns do not exist in SQLite. This one carries what an export reads.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Desktop.Schema.{JSONList, Page}

  @type t :: %__MODULE__{}

  schema "spaces" do
    field :key, :string
    field :name, :string
    field :type, :string, default: "global"
    field :description, :string
    field :homepage_confluence_id, :integer
    field :external_url, :string
    field :labels, JSONList, default: []
    field :icon_path, :string
    field :icon_blob_key, :string
    field :icon_media_type, :string
    field :external_updated_at, :utc_datetime
    field :synced_at, :utc_datetime

    has_many :pages, Page, foreign_key: :space_id

    timestamps(type: :utc_datetime)
  end

  @fields [
    :key,
    :name,
    :type,
    :description,
    :homepage_confluence_id,
    :external_url,
    :labels,
    :icon_path,
    :icon_blob_key,
    :icon_media_type,
    :external_updated_at,
    :synced_at
  ]

  @doc false
  def changeset(space, attrs) do
    space
    |> cast(attrs, @fields)
    |> validate_required([:key, :name])
    |> unique_constraint(:key)
  end
end
