defmodule ConfluencePhxMirror.Repo.Migrations.AddUserProvisionedAt do
  @moduledoc """
  Which accounts the sync made, as opposed to the ones a person claimed here.

  The sync creates an account for every person the site names and will share an
  e-mail for; a magic link, the proxy or the bootstrap account create the others.
  An administrator deciding whether to delete a row should be able to tell them
  apart, and the difference is worth keeping: a provisioned row holds nothing and
  nobody has ever signed in as it.

  Existing rows are left null — every row that predates this is somebody who
  signed in or the bootstrap account.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :provisioned_at, :utc_datetime
    end
  end
end
