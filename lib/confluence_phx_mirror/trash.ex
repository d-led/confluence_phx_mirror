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
  alias ConfluencePhxMirror.Audit.Entry
  alias ConfluencePhxMirror.Mirror.{Counters, Page, Space}

  @doc "Spaces in the trash, newest first, with how many pages go with each."
  def spaces, do: Mirror.trashed_spaces()

  @doc "Trashed pages and blog posts that did not go with a trashed space."
  def pages(opts \\ []), do: Mirror.trashed_pages(opts)

  @doc "Whether there is anything at all to purge."
  def empty? do
    spaces() == [] and pages(limit: 1) == []
  end

  @doc """
  What a retention policy would purge: everything trashed at least `days` ago.

  This is the read half of "delete it later". The trash is a holding area, and a
  mirror that keeps every page it ever saw is a mirror that grows without
  bound — so an operator decides how long is long enough and this says what that
  decision would remove, without removing it.

      Trash.due(30)
      #=> %{spaces: [{space, page_count}], pages: [{page, space}], days: 30}
  """
  @spec due(non_neg_integer()) :: %{
          days: non_neg_integer(),
          spaces: list(),
          pages: list()
        }
  def due(days) when is_integer(days) and days >= 0 do
    cutoff = cutoff(days)

    %{
      days: days,
      spaces: Mirror.trashed_spaces(older_than: cutoff),
      pages: Mirror.trashed_pages(older_than: cutoff)
    }
  end

  @doc """
  Purges everything trashed at least `days` ago, and says what it removed.

  One audit entry per removed row, written by `purge_space/2` and `purge_page/2`,
  so the trail keeps naming what a retention policy took. Blobs go after the rows
  commit, as everywhere else here.
  """
  @spec purge_due(Audit.actor(), non_neg_integer()) :: %{
          days: non_neg_integer(),
          spaces: non_neg_integer(),
          pages: non_neg_integer()
        }
  def purge_due(actor, days) do
    due = due(days)

    Enum.each(due.spaces, fn {space, _pages} -> purge_space(actor, space) end)
    Enum.each(due.pages, fn {page, _space} -> purge_page(actor, page) end)

    %{days: days, spaces: length(due.spaces), pages: length(due.pages)}
  end

  defp cutoff(days), do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

  @doc """
  Purges one trashed space, its pages and everything that hangs off them.

  Blobs are deleted after the rows commit: a failed file delete then leaves a
  file with no row — invisible, and pruned by the next attempt — rather than a
  row pointing at a file that is gone.
  """
  def purge_space(actor, %Space{} = space) do
    with {:ok, %{pages: pages, blob_keys: keys}} <- Mirror.purge_space(space) do
      delete_blobs(keys)
      Counters.clear()
      Audit.log(actor, Space.audit_event_space_purged(space, %{pages: pages}))
      {:ok, %{pages: pages}}
    end
  end

  @doc "Purges one trashed page or blog post, with its comments and attachments."
  def purge_page(actor, %Page{} = page) do
    with {:ok, %{blob_keys: keys}} <- Mirror.purge_page(page) do
      delete_blobs(keys)
      Counters.clear()
      Audit.log(actor, Page.audit_event_purged(page))
      {:ok, :page}
    end
  end

  @doc """
  Moves a page the site no longer lists into the trash.

  The review screen's one action: the page stops being served, its comments go
  with it, and the rows stay for the audit trail until somebody purges them.
  Trashing is reversible in the sense that matters — nothing is served that the
  site does not have, and nothing is lost that a decision cannot restore from the
  site itself.
  """
  @spec trash_page(Audit.actor(), Page.t(), Space.t()) :: {:ok, Page.t()} | {:error, term()}
  def trash_page(actor, %Page{} = page, %Space{} = space) do
    case Mirror.mark_deleted(page.confluence_id, "vanished") do
      {:ok, trashed} ->
        Counters.clear()
        Audit.log(actor, Page.audit_event_trashed(trashed, space))
        {:ok, trashed}

      error ->
        error
    end
  end

  @doc """
  Moves every page the check found missing to the trash, in one go.

  The review screen's per-space button exists because a space is the unit an
  operator reads. This is the same decision without the reading: a site with a
  hundred spaces the site no longer lists, or a check over a hundred thousand
  pages, would otherwise be a hundred clicks, and the pages are already marked —
  the check is what marked them.

  One audit entry for the whole move, because a hundred thousand lines would hide
  the decision instead of recording it. Returns how many pages moved.
  """
  @spec trash_all_absent(Audit.actor()) :: non_neg_integer()
  def trash_all_absent(actor) do
    trashed = Mirror.trash_all_absent()

    if trashed > 0 do
      Counters.clear()

      Audit.log(
        actor,
        Entry.new("pages.deleted", "mirror", nil, %{count: trashed})
      )
    end

    trashed
  end

  defp delete_blobs(keys), do: Enum.each(keys, &Store.delete/1)
end
