defmodule ConfluencePhxMirror.Repo.Migrations.AddUserModeration do
  use Ecto.Migration

  # Two more states an account can be in, both additive: a release that does not
  # know them keeps working.
  #
  #   banned_at       an administrator banned this account here. It stays out
  #                   until the ban is lifted, and it cannot be deleted while the
  #                   ban stands — deleting would let the next sign-in provision
  #                   a fresh account, which is exactly what a ban prevents.
  #   site_deleted_at Confluence no longer has this account at all. That is not
  #                   the same as switching it off, and it is never relaxed.
  def change do
    alter table(:users) do
      add :banned_at, :utc_datetime
      add :site_deleted_at, :utc_datetime
    end
  end
end
