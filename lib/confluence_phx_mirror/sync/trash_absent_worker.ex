defmodule ConfluencePhxMirror.Sync.TrashAbsentWorker do
  @moduledoc """
  Moves a space's absent pages to the trash, off the request that asked.

  `/admin/upstream` reviews a space at a time because that is how an operator
  thinks about it, but a space can hold thousands of pages the site stopped
  listing — too many to move while somebody waits on a click. The job carries the
  decision and the reason somebody made it; the work itself is
  `Mirror.trash_absent_pages/1`, which is the same call the one-page button makes.

  One audit entry per space rather than per page: the sync's own deletion sweep
  records a space's loss the same way (`Space.audit_event_pages_deleted/2`), and
  four thousand identical lines would hide the decision instead of recording it.
  """

  use Oban.Worker, queue: :sync, max_attempts: 1, unique: [period: 300]

  require Logger

  alias ConfluencePhxMirror.{Audit, Mirror}
  alias ConfluencePhxMirror.Mirror.Space

  @impl true
  def perform(%Oban.Job{args: %{"space_key" => space_key} = args}) do
    case Mirror.get_space_by_key(space_key) do
      nil ->
        # The space may have been trashed or purged between the click and the
        # job's turn; there is nothing to move and nothing to record.
        Logger.info("no live space #{space_key} to trash absent pages of")
        :ok

      %Space{} = space ->
        pages = Mirror.absent_pages(space_id: space.id)
        trashed = Mirror.trash_absent_pages(pages)

        Mirror.Counters.clear()

        # Nothing moved means nothing to explain: a job that found the review
        # already settled should not add a line to the audit trail.
        if trashed > 0 do
          Audit.log(actor(args), Space.audit_event_pages_deleted(space, trashed))

          Logger.info("trashed #{trashed} absent pages of #{space.key}",
            space: space.key,
            pages: trashed
          )
        end

        :ok
    end
  end

  # The decision was a person's, and the audit should say whose even though the
  # row is written long after their request finished.
  defp actor(%{"asked_by" => email}) when is_binary(email) do
    {:system, "the upstream review, asked by #{email}"}
  end

  defp actor(_args), do: {:system, "the upstream review"}
end
