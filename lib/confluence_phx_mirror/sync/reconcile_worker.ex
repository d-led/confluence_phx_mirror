defmodule ConfluencePhxMirror.Sync.ReconcileWorker do
  @moduledoc """
  Runs a verify pass off the request, so the admin screen can ask for one.

  A site with hundreds of spaces pays two requests for each, which is minutes at
  a polite pace and far too long to hold a LiveView for. The job is what
  `/admin/upstream` enqueues; the pass itself is `ConfluencePhxMirror.Sync.Reconcile`
  and it never reads a page, only names and counts.
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
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Sync.Reconcile

  @impl true
  def perform(%Oban.Job{args: args}) do
    report = Reconcile.run(source: source(args), trigger: trigger(args))

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
