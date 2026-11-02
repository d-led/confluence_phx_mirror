defmodule ConfluencePhxMirror.Desktop.Schema.Page do
  @moduledoc """
  A mirrored page, blog post or attachment-less document.

  Identity is Confluence's: `confluence_id` within a space, plus the version it
  was read at. A title is not identity — two pages may share one, and a rename
  must not look like a different page.

  The three bodies are kept for the three readers the archive has: storage for
  fidelity, `export` for the HTML a browser gets, and plain text for the search
  index.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Desktop.Schema.{Attachment, Comment, JSONList, Space}

  @type t :: %__MODULE__{}

  schema "pages" do
    field :confluence_id, :integer
    field :parent_id, :integer
    field :type, :string, default: "page"
    field :status, :string, default: "current"
    field :subtype, :string
    field :title, :string
    field :slug, :string
    field :author_name, :string
    field :author_account_id, :string
    field :body_storage, :string
    field :body_export, :string
    field :body_text, :string
    field :labels, JSONList, default: []
    # Ids from the root down to this page's parent. Stored because the archive
    # draws a trail, and recomputing it would mean walking a tree that a single
    # space can be too deep to walk cheaply.
    field :ancestors, JSONList, default: []
    field :version_number, :integer, default: 1
    field :external_url, :string
    field :external_created_at, :utc_datetime
    field :external_updated_at, :utc_datetime
    field :synced_at, :utc_datetime
    field :deleted_at, :utc_datetime

    belongs_to :space, Space

    has_many :attachments, Attachment
    has_many :comments, Comment

    timestamps(type: :utc_datetime)
  end

  @fields [
    :space_id,
    :confluence_id,
    :parent_id,
    :type,
    :status,
    :subtype,
    :title,
    :slug,
    :author_name,
    :author_account_id,
    :body_storage,
    :body_export,
    :body_text,
    :labels,
    :ancestors,
    :version_number,
    :external_url,
    :external_created_at,
    :external_updated_at,
    :synced_at,
    :deleted_at
  ]

  @doc false
  def changeset(page, attrs) do
    page
    |> cast(attrs, @fields)
    |> validate_required([:space_id, :confluence_id, :title])
    |> unique_constraint([:space_id, :confluence_id])
  end
end
