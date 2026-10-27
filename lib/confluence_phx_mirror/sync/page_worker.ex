defmodule ConfluencePhxMirror.Sync.PageWorker do
  @moduledoc """
  Pulls one page, typically triggered by a webhook.

  Jobs for the same page within a minute are coalesced (`unique`), because
  Confluence often sends several events for one edit.

  The outcome is left to `Sync.run/2`, which records a failed run and re-raises
  so that Oban retries; a run that returns is a run that finished.

  A sync already in flight makes this job wait rather than drop the edit: the
  webhook said a page changed, and snoozing keeps that promise.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [period: 60, keys: [:confluence_id], states: :incomplete]

  alias ConfluencePhxMirror.Sync

  @default_trigger "a webhook"
  @actor {:system, "page-worker"}

  @impl true
  def perform(%Oban.Job{id: job_id, args: %{"confluence_id" => id} = args}) do
    case Sync.run(:page,
           confluence_id: confluence_id(id),
           job_id: job_id,
           actor: @actor,
           trigger: trigger(args)
         ) do
      {:ok, _run} ->
        :ok

      {:error, :already_running} ->
        Sync.wait_or_stand_down()
    end
  end

  # Job arguments survive a round trip through JSON, so an id may come back as
  # the number it was queued as or as the string a webhook payload carried.
  defp confluence_id(id) when is_integer(id), do: id
  defp confluence_id(id), do: String.to_integer(id)

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: trigger

  defp trigger(_args), do: @default_trigger
end
