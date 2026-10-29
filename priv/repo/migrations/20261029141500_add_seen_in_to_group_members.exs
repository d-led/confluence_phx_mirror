defmodule ConfluencePhxMirror.Repo.Migrations.AddSeenInToGroupMembers do
  use Ecto.Migration

  # A migration that builds an index must not hold anything else back: both
  # flags are needed, because the migrator's advisory lock is a transaction of
  # its own and a concurrent build waits for every open one.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # A group's membership is read a page at a time, so "who is still in it" has
  # to be answerable without holding the group: each page carries the marker of
  # the read that wrote it, and the rows that kept an older one are gone.
  #
  # The account id is indexed too: it is what an identity is looked up by, for
  # every access question and for every person who signs in — on a site with
  # half a million members, a scan is not an answer.
  def change do
    alter table(:group_members) do
      add :seen_in, :bigint
    end

    create index(:group_members, [:group_key, :seen_in], concurrently: true)
    create index(:group_members, [:account_id], concurrently: true)
  end
end
