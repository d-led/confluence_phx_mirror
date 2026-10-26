defmodule ConfluencePhxMirror.Sync.ReconcileWorker do
  @moduledoc """
  Runs a verify pass off the request, so the admin screen can ask for one.

  A site with hundreds of spaces pays two requests for each, which is minutes at
  a polite pace and far too long to hold a LiveView for. The job is what
  `/admin/upstream` enqueues; the pass itself is `ConfluencePhxMirror.Sync.Reconcile`
  and it never reads a page, only names and counts.
  """

  use Oban.Worker, queue: :sync, max_attempts: 1, unique: [period: 300]

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
