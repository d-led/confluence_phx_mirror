defmodule ConfluencePhxMirror.Repo.Migrations.CreateObanJobs do
  @moduledoc false
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)

  def down, do: Oban.Migration.down(version: 1)
end
