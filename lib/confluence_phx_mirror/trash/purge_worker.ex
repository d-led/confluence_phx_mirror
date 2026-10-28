defmodule ConfluencePhxMirror.Trash.PurgeWorker do
  @moduledoc """
  Removes what a holding period has expired, off the request that asked.

  Emptying the trash is the same shape as filling it: a mirror that ran for a
  year can have tens of thousands of rows and their attachment files waiting, and
  a request that tries to delete them either times out or is killed halfway. The
  job carries the number of days — the whole policy, since the cutoff is derived
  from it — and `Trash.purge_due/2` does the work one row at a time, auditing each
  removal and deleting a page's blobs only after its rows commit.

  `Trash.due/1` is what the screen showed before the click, so the operator's
  "delete these 412" and the job's work are the same question asked once more.
  """

  # One purge at a time: two of them would walk the same expired rows, take the
  # same locks and audit the same work twice.
  use Oban.Worker,
    queue: :sync,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Trash

  @impl true
  def perform(%Oban.Job{args: args}) do
    case retention_days(args) do
      0 ->
        :ok

      days ->
        %{spaces: spaces, pages: pages} = Trash.purge_due(actor(args), days)

        Logger.info("purged #{spaces} spaces and #{pages} pages trashed #{days} days ago or more")

        :ok
    end
  end

  # The screen hands the number it showed before the click; the nightly job has
  # none of its own and takes the deployment's (`trash.retention_days`). Zero
  # means "keep the trash": nothing to do, and no reason to walk it.
  defp retention_days(%{"older_than_days" => days}) when is_integer(days), do: days
  defp retention_days(_args), do: Trash.retention_days()

  defp actor(%{"asked_by" => email}) when is_binary(email) do
    {:system, "the retention policy, asked by #{email}"}
  end

  defp actor(_args), do: {:system, "the retention policy"}
end
