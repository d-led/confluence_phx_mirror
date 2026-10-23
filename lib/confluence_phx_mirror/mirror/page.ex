defmodule ConfluencePhxMirror.Mirror.Page do
  @moduledoc """
  A mirrored Confluence page or blog post.

  `body_storage` keeps the Confluence storage format for auditing and for the
  REST API's `body.storage` expansion; `body_export` is Confluence's own
  `export_view` rendering (macros included) after link rewriting and
  sanitising. `body_text` is the plain text used for full-text search.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @type t :: %__MODULE__{}

  @types ~w(page blogpost)
  @statuses ~w(current draft archived)

  schema "pages" do
    field :confluence_id, :integer
    field :type, :string, default: "page"
    field :status, :string, default: "current"
    field :title, :string
    field :slug, :string
    field :author_name, :string
    field :author_account_id, :string
    field :body_storage, :string
    field :body_export, :string
    field :body_text, :string
    field :labels, {:array, :string}, default: []
    field :ancestors, {:array, :integer}, default: []
    field :version_number, :integer, default: 1
    field :version_message, :string
    field :external_url, :string
    field :external_created_at, :utc_datetime
    field :external_updated_at, :utc_datetime
    field :synced_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :search_text, :string, default: ""

    belongs_to :space, ConfluencePhxMirror.Mirror.Space
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :attachments, ConfluencePhxMirror.Mirror.Attachment
    has_many :comments, ConfluencePhxMirror.Mirror.Comment
    has_many :outgoing_links, ConfluencePhxMirror.Mirror.Link, foreign_key: :source_page_id
    has_many :incoming_links, ConfluencePhxMirror.Mirror.Link, foreign_key: :target_page_id
    has_many :properties, ConfluencePhxMirror.Mirror.PageProperty

    many_to_many :label_records, ConfluencePhxMirror.Mirror.Label,
      join_through: "page_labels",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @required_fields [:confluence_id, :space_id, :title, :slug]
  @optional_fields [
    :parent_id,
    :type,
    :status,
    :author_name,
    :author_account_id,
    :body_storage,
    :body_export,
    :body_text,
    :labels,
    :ancestors,
    :version_number,
    :version_message,
    :external_url,
    :external_created_at,
    :external_updated_at,
    :synced_at,
    :deleted_at,
    :search_text
  ]

  def changeset(page, attrs) do
    page
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:confluence_id)
  end

  @doc "The title slug used in pretty mirror URLs."
  def slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
    |> case do
      "" -> "page"
      slug -> slug
    end
  end

  def audit_event_purged(%__MODULE__{} = page) do
    Entry.new("page.purged", "page", to_string(page.confluence_id), %{
      title: page.title,
      type: page.type
    })
  end
end
