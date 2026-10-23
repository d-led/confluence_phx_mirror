defmodule ConfluencePhxMirror.Repo.Migrations.CreateSettings do
  @moduledoc """
  A key/value table for decisions an administrator makes at runtime, as opposed
  to the environment the mirror booted with. Today that is the site skin; the
  shape stays generic so the next setting does not need a table of its own.
  """
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :string
    end

    create unique_index(:settings, [:key])
  end
end
