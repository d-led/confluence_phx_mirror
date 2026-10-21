defmodule ConfluencePhxMirror.Mirror.PageProperty do
  @moduledoc """
  One row of a page's `pageproperties` table, extracted during sync.

  Confluence does not resolve property macros in `export_view`; the mirror
  stores the pairs so it can render property reports statically.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Mirror.Page

  @type t :: %__MODULE__{}

  schema "page_properties" do
    field :key, :string
    field :value, :string

    belongs_to :page, Page

    timestamps(type: :utc_datetime)
  end

  def changeset(property, attrs) do
    property
    |> cast(attrs, [:page_id, :key, :value])
    |> validate_required([:page_id, :key])
  end
end
