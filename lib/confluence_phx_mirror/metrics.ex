defmodule ConfluencePhxMirror.Metrics do
  @moduledoc """
  What the mirror holds, published as one `[:confluence_mirror, :catalogue]`
  event for whoever is watching — the runtime dashboard's Metrics page, a
  scraper, a log reporter.

  Two callers, because two questions. The poller publishes every ten seconds so
  a chart has a value even when nothing happens; `Sync.run/2` publishes when a
  run ends, so an import lands a point at the moment it finished instead of up
  to a tick later.

  The counts are the mirror's own cached totals (`Mirror.Counters`), so a quiet
  mirror costs one version probe; the two sizes come from `Resources`, which
  keeps the walk of the blob mount on its own schedule.
  """

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Resources

  @event [:confluence_mirror, :catalogue]

  @doc "Publish the current totals."
  def publish, do: :telemetry.execute(@event, measurements(), %{})

  @doc """
  The measurements, without publishing them.

  Public for the tests and for anything that wants the numbers rather than the
  event.
  """
  def measurements do
    stats = Mirror.stats()
    mount = Resources.mount()
    database = Resources.database()

    %{
      pages: stats.pages,
      spaces: stats.spaces,
      attachments: stats.attachments,
      comments: stats.comments,
      labels: stats.labels,
      trashed_pages: stats.trashed_pages,
      trashed_spaces: stats.trashed_spaces,
      users: Accounts.count_users(),
      blob_bytes: mount.used_bytes,
      database_bytes: database.bytes
    }
  end
end
