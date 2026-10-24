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
    # Comments, attachments and restrictions have versions of their own and
    # none of them bumps the page's. This is when the page's details were last
    # read, so a run that missed them can find the page again.
    field :details_synced_at, :utc_datetime
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

  # `slug` is not required: a title with no ASCII words in it (Cyrillic, CJK)
  # has no URL segment at all, and Confluence serves those pages by id.
  @required_fields [:confluence_id, :space_id, :title]
  @optional_fields [
    :slug,
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
    :details_synced_at,
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

  @doc """
  The trailing segment Confluence puts in a page URL.

  Confluence keeps ASCII word characters and turns every run of anything else
  into a single `+`, then drops the segment when nothing survives — which is
  what a Cyrillic, CJK or punctuation-only title ends up as:

      "API /v2: changelog? (draft) #2"  ->  "API+v2+changelog+draft+2"
      "Rocket 🚀 launch"                 ->  "Rocket+launch"
      "Обзор проекта"                     ->  ""   (served by id alone)

  Mirroring the rule is the point: a Confluence page URL works here with the
  host swapped and nothing else, and a link copied from this mirror works in
  Confluence. Titles differ from what the old rule produced (lower case,
  hyphens), which the sync backfills.
  """
  def slugify(title) do
    title
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]+/, "+")
    |> String.trim("+")
    |> String.slice(0, 255)
    |> String.trim_trailing("+")
  end

  @doc """
  Whether a URL's trailing segment names this page.

  `+` is a word separator in a Confluence URL and a space is what it means when
  a client percent-encodes it instead, so the two are the same here. Anything
  else — an old slug, a typo, a title that has since been renamed — does not
  match, and the controller redirects to the canonical URL.
  """
  @spec slug_match?(t(), String.t() | nil) :: boolean()
  def slug_match?(%__MODULE__{slug: slug}, requested) do
    normalise_slug(slug) == normalise_slug(requested)
  end

  defp normalise_slug(slug) do
    slug
    |> to_string()
    |> String.replace("+", " ")
    |> String.trim()
  end

  @doc """
  How many levels below `root` this page sits — 1 for a direct child.

  Both subtree listings (the JSON API's `/pages/:id/descendants` and the MCP
  tool) report it, and both read it from the same denormalised trail, so the
  rule is stated once.
  """
  @spec depth_below(t(), t()) :: non_neg_integer()
  def depth_below(%__MODULE__{ancestors: trail}, %__MODULE__{ancestors: root_trail}) do
    length(trail || []) - length(root_trail || [])
  end

  @doc "The Confluence id of the page directly above this one, when the trail names it."
  @spec parent_confluence_id(t()) :: integer() | nil
  def parent_confluence_id(%__MODULE__{ancestors: trail}) do
    trail |> List.wrap() |> List.last()
  end

  def audit_event_purged(%__MODULE__{} = page) do
    Entry.new("page.purged", "page", to_string(page.confluence_id), %{
      title: page.title,
      type: page.type
    })
  end
end
