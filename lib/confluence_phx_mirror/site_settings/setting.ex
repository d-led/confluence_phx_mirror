defmodule ConfluencePhxMirror.SiteSettings.Setting do
  @moduledoc """
  The site's own configuration as the mirror last read it.

  One row, because a mirror serves one site: the primary key is the constant 1.
  `fetched_at` is when the site said it — there is no other row that could say
  it first — and a row that has never been written means no source has told us,
  so every reader of this table treats "no row" as "the site has no opinion".
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}
  schema "site_settings" do
    field :title, :string
    field :locale, :string
    field :timezone, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @fields [:title, :locale, :timezone, :fetched_at]

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @fields)
    |> validate_required([:fetched_at])
  end
end
