defmodule ConfluencePhxMirror.Mirror.Space do
  @moduledoc """
  A mirrored Confluence space.

  `key` is the Confluence space key; `homepage_confluence_id` points at the
  page that acts as the space home in the mirror. `icon_*` describe the space
  icon Confluence shows beside the space name: its upstream path (which carries
  the version), and the mirrored bytes in the blob store. `labels` are the
  space's own labels — its Confluence *categories* — not the labels of its
  pages.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @type t :: %__MODULE__{}

  schema "spaces" do
    field :key, :string
    field :name, :string
    field :type, :string, default: "global"
    field :description, :string
    field :homepage_confluence_id, :integer
    field :external_url, :string
    field :labels, {:array, :string}, default: []
    field :icon_path, :string
    field :icon_blob_key, :string
    field :icon_media_type, :string
    field :icon_sha256, :string
    field :synced_at, :utc_datetime
    field :deleted_at, :utc_datetime

    has_many :pages, ConfluencePhxMirror.Mirror.Page

    timestamps(type: :utc_datetime)
  end

  @required_fields [:key, :name]

  @optional_fields [
    :type,
    :description,
    :homepage_confluence_id,
    :external_url,
    :labels,
    :icon_path,
    :icon_blob_key,
    :icon_media_type,
    :icon_sha256,
    :synced_at
  ]

  @doc "A space key as the mirror stores it: Confluence keys are case-insensitive."
  def normalise_key(key) when is_binary(key), do: String.upcase(key)
  def normalise_key(key), do: key

  def changeset(space, attrs) do
    space
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> update_change(:key, &normalise_key/1)
    |> validate_format(:key, ~r/^[A-Z0-9_~.-]+$/, message: "is not a valid space key")
    |> unique_constraint(:key)
  end

  @doc "Audit entry for pages a sync stopped finding in Confluence."
  def audit_event_pages_deleted(%__MODULE__{} = space, count) do
    Entry.new("pages.deleted", "space", space.key, %{count: count})
  end

  def audit_event_space_deleted(%__MODULE__{} = space, pages) do
    Entry.new("space.deleted", "space", space.key, %{pages: pages})
  end

  def audit_event_space_purged(%__MODULE__{} = space, counts) do
    Entry.new("space.purged", "space", space.key, counts)
  end
end
