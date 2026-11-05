defmodule ConfluencePhxMirror.Mirror.Person do
  @moduledoc """
  One person the site names: a name, and the picture the site publishes.

  Not an account. A Confluence byline names people who never sign in here, and a
  person whose address the site does not share cannot be an account at all — so
  this row is what the mirror knows about a face, kept apart from `users`, which
  is about readers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "people" do
    field :account_id, :string
    field :display_name, :string
    field :avatar_blob_key, :string
    field :avatar_media_type, :string
    field :avatar_sha256, :string
    field :synced_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @fields [
    :account_id,
    :display_name,
    :avatar_blob_key,
    :avatar_media_type,
    :avatar_sha256,
    :synced_at
  ]

  def changeset(person, attrs) do
    person
    |> cast(attrs, @fields)
    |> validate_required([:account_id])
    |> unique_constraint(:account_id)
  end

  @doc "Whether the row has a picture a reader can be shown."
  def pictured?(%__MODULE__{avatar_blob_key: key}), do: is_binary(key) and key != ""
end
