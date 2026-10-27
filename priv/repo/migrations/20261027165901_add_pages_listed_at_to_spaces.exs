defmodule ConfluencePhxMirror.Repo.Migrations.AddPagesListedAtToSpaces do
  @moduledoc """
  When a space's *page listing* was last read — which is not the same as when the
  space row was written.

  A page that changes in a space the mirror has never seen makes `ensure_space/3`
  create the row and import that one page, and an incremental run's window only
  ever names pages that moved inside it. Without a marker for "this space has
  never been listed", neither case can be told apart from a space that is fully
  mirrored, so a space could stay half-imported (or absent) for ever, waiting for
  a snapshot nobody knew to run.

  The column starts empty on purpose: no backfill. A mirror upgraded to this
  version therefore re-lists every space once — which is the repair production
  needs — and marks each as it goes, so an interruption resumes where it stopped.
  """
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :pages_listed_at, :utc_datetime
    end
  end
end
