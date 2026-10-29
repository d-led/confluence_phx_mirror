defmodule ConfluencePhxMirror.Sync.ReconcileWorker do
  @moduledoc """
  Runs a verify pass off the request, so the admin screen can ask for one.

  A site with hundreds of spaces pays two requests for each, which is minutes at
  a polite pace and far too long to hold a LiveView for. `/admin/upstream`
  enqueues it on a button, and `CM_RECONCILE_INTERVAL_SECONDS` on a clock; the
  pass itself is `ConfluencePhxMirror.Sync.Reconcile` and it never reads a page,
  only names and counts.

  The pass takes the same lock a run does (`Sync.Gate`), for the reason the lock
  exists: it is one more process asking the whole site questions at once, and
  the mirror answers one at a time. Holding it is also the only evidence that a
  job still has a process behind it, which is what lets
  `Sync.abandon_abandoned_runs/0` clear a pass a deploy killed — production left
  one `executing` for six hours, because nothing could tell it apart from a pass
  still working, and its uniqueness turned every later schedule away. A pass that
  finds the lock taken waits for it; nothing is lost, because each settled space
  is recorded and the next turn finishes the pass instead of repeating it.
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
  alias ConfluencePhxMirror.Sync.{Gate, Reconcile}

  # How long a pass waits for a sync to finish before asking again. Short enough
  # that a pass follows a run closely, long enough that a queue of them does not
  # become a poll: a snooze costs no attempt.
  @wait_for_the_lock 60

  @impl true
  def perform(%Oban.Job{args: args}) do
    if Settings.sync_paused?() do
      # A verify pass is a run of requests against the site, so a paused mirror
      # does not make it: the job waits for the resume instead of failing.
      Logger.info("verify pass waiting: Confluence calls are paused")
      Sync.paused_wait()
    else
      pass(args)
    end
  end

  defp pass(args) do
    case Gate.exclusive(fn _owner ->
           Reconcile.run(source: source(args), trigger: trigger(args))
         end) do
      {:ok, report} -> count(report)
      {:error, :already_running} -> {:snooze, @wait_for_the_lock}
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
