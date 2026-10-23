defmodule ConfluencePhxMirror.Trash do
  @moduledoc """
  What a sync trashes, and what an administrator can purge.

  Two kinds of removal, on purpose:

    * a **sync** never deletes content. A page, blog post, comment or space that
      disappears in Confluence is marked deleted (`deleted_at`), so an operator
      mistake — wrong site, revoked permission, a source that listed nothing —
      stays reversible and the audit trail stays readable;
    * an **administrator** empties the trash from `/admin/trash`, which removes
      the rows and the attachment blobs for good.

  Purges refuse anything that is still live, so the trash screen cannot become a
  "delete a space" button by accident.
  """

  alias ConfluencePhxMirror.{Audit, Blobs.Store, Mirror}
  alias ConfluencePhxMirror.Mirror.{Page, Space}

  @doc "Spaces in the trash, newest first, with how many pages go with each."
  def spaces, do: Mirror.trashed_spaces()

  @doc "Trashed pages and blog posts that did not go with a trashed space."
  def pages(opts \\ []), do: Mirror.trashed_pages(opts)

  @doc "Whether there is anything at all to purge."
  def empty? do
    spaces() == [] and pages(limit: 1) == []
  end

  @doc """
  Purges one trashed space, its pages and everything that hangs off them.

  Blobs are deleted after the rows commit: a failed file delete then leaves a
  file with no row — invisible, and pruned by the next attempt — rather than a
  row pointing at a file that is gone.
  """
  def purge_space(actor, %Space{} = space) do
    with {:ok, %{pages: pages, blob_keys: keys}} <- Mirror.purge_space(space) do
      delete_blobs(keys)
      Audit.log(actor, Space.audit_event_space_purged(space, %{pages: pages}))
      {:ok, %{pages: pages}}
    end
  end

  @doc "Purges one trashed page or blog post, with its comments and attachments."
  def purge_page(actor, %Page{} = page) do
    with {:ok, %{blob_keys: keys}} <- Mirror.purge_page(page) do
      delete_blobs(keys)
      Audit.log(actor, Page.audit_event_purged(page))
      {:ok, :page}
    end
  end

  defp delete_blobs(keys), do: Enum.each(keys, &Store.delete/1)
end
