defmodule ConfluencePhxMirror.Repo.Migrations.IndexPagesSpaceRecent do
  @moduledoc """
  The "newest pages in this space" index.

  The space overview's recent list (`Mirror.recent_pages_for_space/3`) asks for
  six rows of one space, newest first. The only ordering index was
  `pages(external_updated_at)`, and the planner trusts it: a backwards walk with
  a `space_id` filter, stopping once six rows survive. Whether that is fast
  depends on the data, not on the query — in a 60k-page development mirror the
  walk discarded 57,200 rows to find the six, so the cost grows with the whole
  table rather than with the space.

  `(space_id, external_updated_at DESC)` turns that walk into six index entries.
  Measured on a copy of that development table: 237 ms and 57,916 buffers on the
  old plan, 0.6 ms and 9 buffers with this index.

  The global `pages(external_updated_at)` index stays: the home page's "recent
  changes" asks across every space, and this one cannot answer that order.
  """
  use Ecto.Migration

  # Built while a deploy is serving readers, so it is CONCURRENTLY — which needs
  # both flags (see docs/operations.md).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:pages, ["space_id", "external_updated_at DESC"],
             name: :pages_space_recent_index,
             concurrently: true
           )
  end
end
