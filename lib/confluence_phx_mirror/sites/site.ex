defmodule ConfluencePhxMirror.Sites.Site do
  @moduledoc """
  The one site a mirror database belongs to.

  A single row (`id` is always 1): the Confluence site whose content this
  database holds. The mirror checks it before every sync, so pointing the app at
  a database that was filled from another site fails loudly instead of blending
  two sources.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}
  schema "mirror_sites" do
    field :key, :string
    field :base_url, :string
    field :source, :string
    field :kind, :string, default: "demo"

    timestamps(type: :utc_datetime)
  end

  @fields [:key, :base_url, :source, :kind]

  @doc false
  def changeset(site, attrs) do
    site
    |> cast(attrs, [:id | @fields])
    |> validate_required([:id, :key, :kind])
    |> validate_inclusion(:kind, ~w(demo live))
    |> unique_constraint(:id, name: :mirror_sites_pkey)
  end

  @doc "Whether this database holds the demo snapshot rather than a real site."
  def demo?(%__MODULE__{kind: "demo"}), do: true
  def demo?(%__MODULE__{}), do: false
end
