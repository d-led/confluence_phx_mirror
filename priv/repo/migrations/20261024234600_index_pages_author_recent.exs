defmodule ConfluencePhxMirror.Repo.Migrations.IndexPagesAuthorRecent do
  @moduledoc """
  The "newest pages by this author" index, for the people directory.

  `Catalog.pages_by_author/3` reads one account's pages newest first. There was
  no index on `author_account_id` at all, so the statement was a sequential scan
  of `pages` followed by a sort: 74 ms and 7,708 buffers on a 60k-page mirror,
  and it grows with the table. With `(author_account_id, external_updated_at
  DESC)` a copy of the same table answered in 0.08 ms.

  Small enough to belong next to `pages_space_recent_index`: they are the same
  shape — a filtered "newest first" window — and the same mistake.
  """
  use Ecto.Migration

  # Built while a deploy is serving readers, so it is CONCURRENTLY — which needs
  # both flags (see docs/operations.md).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:pages, ["author_account_id", "external_updated_at DESC"],
             name: :pages_author_recent_index,
             concurrently: true
           )
  end
end
