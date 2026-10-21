defmodule ConfluencePhxMirror.Mirror.Attachment do
  @moduledoc """
  A file attached to a mirrored page. The bytes live in the configured blob
  store under `blob_key`; Postgres only keeps the metadata.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "attachments" do
    field :confluence_id, :integer
    field :filename, :string
    field :media_type, :string, default: "application/octet-stream"
    field :byte_size, :integer
    field :version_number, :integer, default: 1
    field :download_url, :string
    field :blob_key, :string
    field :sha256, :string
    field :external_updated_at, :utc_datetime
    field :synced_at, :utc_datetime

    belongs_to :page, ConfluencePhxMirror.Mirror.Page

    timestamps(type: :utc_datetime)
  end

  @fields [
    :confluence_id,
    :page_id,
    :filename,
    :media_type,
    :byte_size,
    :version_number,
    :download_url,
    :blob_key,
    :sha256,
    :external_updated_at,
    :synced_at
  ]

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, @fields)
    |> validate_required([:confluence_id, :page_id, :filename])
    |> unique_constraint(:confluence_id)
    |> unique_constraint([:page_id, :filename])
  end

  @doc "Human readable size, e.g. `1.4 MB`."
  def human_size(nil), do: "unknown size"

  def human_size(bytes) when bytes < 1024, do: "#{bytes} B"

  def human_size(bytes) do
    units = ~w(KB MB GB TB)
    scale = bytes |> :math.log10() |> Kernel./(3) |> trunc()

    unit = Enum.at(units, min(scale - 1, length(units) - 1))
    value = bytes / :math.pow(1024, scale)
    "#{Float.round(value * 1.0, 1)} #{unit}"
  end
end
