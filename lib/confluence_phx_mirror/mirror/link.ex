defmodule ConfluencePhxMirror.Mirror.Link do
  @moduledoc """
  A hyperlink found in a page's export view.

  `kind` is `"internal"` when the target page exists in the mirror,
  `"attachment"` for mirrored files and `"external"` for everything that still
  points at the original Confluence or the wider web. Internal links are what
  makes cross-linking and backlinks possible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(internal attachment external)

  schema "links" do
    field :href, :string
    field :kind, :string, default: "external"
    field :label, :string
    field :target_confluence_id, :integer

    belongs_to :source_page, ConfluencePhxMirror.Mirror.Page
    belongs_to :target_page, ConfluencePhxMirror.Mirror.Page

    timestamps(type: :utc_datetime)
  end

  @fields [:source_page_id, :target_page_id, :target_confluence_id, :href, :kind, :label]

  def changeset(link, attrs) do
    link
    |> cast(attrs, @fields)
    |> validate_required([:source_page_id, :href])
    |> validate_inclusion(:kind, @kinds)
  end
end
