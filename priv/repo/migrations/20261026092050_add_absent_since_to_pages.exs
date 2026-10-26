defmodule ConfluencePhxMirror.Repo.Migrations.AddAbsentSinceToPages do
  @moduledoc """
  When a page stopped being listed by the site, for an administrator to review.

  A sync that lists a whole space already notices pages the site no longer
  returns and trashes them (`Mirror.mark_missing_deleted/2`). This column is for
  the other question: which of the pages we hold did the site not list — asked by
  a *verify* pass that reads no content at all, so an operator can see the
  difference before anything moves to the trash.

  `absent_since` is the moment the mirror first noticed, cleared as soon as the
  site lists the page again. `deleted_reason` says why a trashed row is in the
  trash — `"vanished"` when the site stopped listing it, `"manual"` when somebody
  decided, NULL for the rows written before this column existed.

  A deploy serves readers while this runs, so the columns are added without a
  rewrite lock and the index is built CONCURRENTLY (see docs/operations.md).
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:pages) do
      add :absent_since, :utc_datetime
      add :deleted_reason, :string
    end

    # The review screen asks "which pages are absent?" — a small slice of a
    # table that is otherwise every page in the mirror.
    create index(:pages, [:absent_since],
             where: "absent_since is not null",
             concurrently: true,
             name: :pages_absent_since_index
           )
  end
end
