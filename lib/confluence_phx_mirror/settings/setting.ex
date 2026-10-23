defmodule ConfluencePhxMirror.Settings.Setting do
  @moduledoc """
  One row of the `settings` table: a key an administrator decided and its value.

  The schema is deliberately blank about meaning — `ConfluencePhxMirror.Settings`
  owns the keys and the validation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{key: String.t() | nil, value: String.t() | nil}

  schema "settings" do
    field :key, :string
    field :value, :string
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
