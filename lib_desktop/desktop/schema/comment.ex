defmodule ConfluencePhxMirror.Desktop.Schema.Comment do
  @moduledoc """
  A comment on a page.

  Kept because a reader remembers the discussion as often as the page, and
  because an archive that silently drops it is answering a different question
  from the one asked.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Desktop.Schema.Page

  @type t :: %__MODULE__{}

  schema "comments" do
    field :confluence_id, :integer
    field :parent_id, :integer
    field :author_name, :string
    field :author_account_id, :string
    field :body_export, :string
    field :body_text, :string
    field :external_url, :string
    field :external_created_at, :utc_datetime
    field :external_updated_at, :utc_datetime
    field :version_number, :integer, default: 1
    field :synced_at, :utc_datetime
    field :deleted_at, :utc_datetime

    belongs_to :page, Page

    timestamps(type: :utc_datetime)
  end

  @fields [
    :page_id,
    :confluence_id,
    :parent_id,
    :author_name,
    :author_account_id,
    :body_export,
    :body_text,
    :external_url,
    :external_created_at,
    :external_updated_at,
    :version_number,
    :synced_at,
    :deleted_at
  ]

  @doc false
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @fields)
    |> validate_required([:page_id, :confluence_id])
    |> unique_constraint([:page_id, :confluence_id])
  end
end
