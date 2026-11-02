defmodule ConfluencePhxMirror.Desktop.Schema.Attachment do
  @moduledoc """
  A file mirrored beside a page.

  The bytes are not here: `blob_key` addresses them in `Blobs.Store`, which for
  this build is a folder. A catalogue row that fails to be written therefore
  never leaves a half-file, and a file without a row is swept rather than
  served.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Desktop.Schema.Page

  @type t :: %__MODULE__{}

  schema "attachments" do
    # Confluence's attachment id is a string in the REST API even though it is
    # numeric, and an id is compared, never computed on.
    field :confluence_id, :string
    field :comment_id, :integer
    field :filename, :string
    field :media_type, :string, default: "application/octet-stream"
    field :byte_size, :integer
    field :version_number, :integer, default: 1
    field :download_url, :string
    field :blob_key, :string
    field :external_updated_at, :utc_datetime
    field :synced_at, :utc_datetime

    belongs_to :page, Page

    timestamps(type: :utc_datetime)
  end

  @fields [
    :page_id,
    :comment_id,
    :confluence_id,
    :filename,
    :media_type,
    :byte_size,
    :version_number,
    :download_url,
    :blob_key,
    :external_updated_at,
    :synced_at
  ]

  @doc false
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, @fields)
    |> validate_required([:page_id, :confluence_id, :filename])
    |> unique_constraint([:page_id, :confluence_id])
  end
end
