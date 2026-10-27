defmodule ConfluencePhxMirror.Sync.ReconcileWorker do
  @moduledoc """
  Runs a verify pass off the request, so the admin screen can ask for one.

  A site with hundreds of spaces pays two requests for each, which is minutes at
  a polite pace and far too long to hold a LiveView for. `/admin/upstream`
  enqueues it on a button, and `CM_RECONCILE_INTERVAL_SECONDS` on a clock; the
  pass itself is `ConfluencePhxMirror.Sync.Reconcile` and it never reads a page,
  only names and counts.
  """

  # One pass at a time, whatever it was asked for. Uniqueness on the default
  # fields would key on the arguments, and the arguments carry the operator's
  # address — so two people pressing the button, or one whose address changed,
  # would each get their own pass reading the whole site twice. `fields:
  # [:worker, :queue]` ignores the arguments, and `states: :incomplete` refuses a
  # second job while the first is queued, running or retrying while still
  # allowing a fresh check the moment one finishes. `period: :infinity` matters
  # for the same reason: a period is measured from the job's `inserted_at`, so a
  # pass over a hundred thousand pages would otherwise stop blocking while it was
  # still running.
  # `max_attempts: 3` is safe now that the pass records what it learned space by
  # space: a retry — including the one `lifeline` performs on a job whose node
  # died, which is how a long pass usually ends — continues where it stopped
  # instead of asking the whole site again.
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.Reconcile

  @impl true
  def perform(%Oban.Job{args: args}) do
    if Settings.sync_paused?() do
      # A verify pass is a run of requests against the site, so a paused mirror
      # does not make it: the job waits for the resume instead of failing.
      Logger.info("verify pass waiting: Confluence calls are paused")
      Sync.paused_wait()
    else
      count(Reconcile.run(source: source(args), trigger: trigger(args)))
    end
  end

  defp count(report) do
    Logger.info(
      "verify pass over #{report.spaces} spaces (#{report.agreed} already in step, " <>
        "#{length(report.listed)} listed, #{report.absent} pages absent) " <>
        "for #{report.asked} questions"
    )

    :ok
  end

  # The job names no source: a verify pass asks the same site the sync mirrors,
  # and a job that carried a module name would let any enqueuer choose it.
  defp source(_args), do: ConfluencePhxMirror.Confluence.Source.source()

  # Why the pass happened, in words, for the record `Reconcile` keeps.
  defp trigger(%{"trigger" => trigger}) when is_binary(trigger), do: trigger
  defp trigger(_args), do: "the admin screen"
end
