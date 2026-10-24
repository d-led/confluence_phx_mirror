defmodule ConfluencePhxMirror.Mirror.Comment do
  @moduledoc """
  A mirrored page comment, rendered from Confluence's export view.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "comments" do
    field :confluence_id, :integer
    field :author_name, :string
    field :author_account_id, :string
    field :body_export, :string
    field :body_text, :string
    field :external_url, :string
    field :external_created_at, :utc_datetime
    # Which version of the comment the mirror holds, so "is this current?" has
    # an answer for comments the way it does for pages and attachments.
    field :version_number, :integer
    field :external_updated_at, :utc_datetime
    field :synced_at, :utc_datetime
    field :deleted_at, :utc_datetime

    belongs_to :page, ConfluencePhxMirror.Mirror.Page
    belongs_to :parent, __MODULE__

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :confluence_id,
      :page_id,
      :parent_id,
      :author_name,
      :author_account_id,
      :body_export,
      :body_text,
      :external_url,
      :external_created_at,
      :version_number,
      :external_updated_at,
      :synced_at
    ])
    |> validate_required([:confluence_id, :page_id])
    |> unique_constraint(:confluence_id)
  end
end
