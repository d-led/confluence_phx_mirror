defmodule ConfluencePhxMirror.Mirror.Label do
  @moduledoc """
  A Confluence label. Labels are normalised to lower case; the same label can
  appear on pages of different spaces, like on Confluence.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "labels" do
    field :name, :string

    many_to_many :pages, ConfluencePhxMirror.Mirror.Page,
      join_through: "page_labels",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> update_change(:name, &normalise/1)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9 _-]*$/, message: "is not a valid label")
    |> unique_constraint(:name)
  end

  def normalise(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
