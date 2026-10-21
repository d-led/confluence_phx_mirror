defmodule ConfluencePhxMirror.Sync.PageWorker do
  @moduledoc """
  Pulls one page, typically triggered by a webhook.

  Jobs for the same page within a minute are coalesced (`unique`), because
  Confluence often sends several events for one edit.
  """

  use Oban.Worker, queue: :sync, max_attempts: 5, unique: [period: 60, keys: [:confluence_id]]

  alias ConfluencePhxMirror.Sync

  @impl true
  def perform(%Oban.Job{args: %{"confluence_id" => id}}) do
    confluence_id = to_integer(id)

    case Sync.run(:page, confluence_id: confluence_id, actor: {:system, "page-worker"}) do
      {:ok, %{status: "failed"} = run} -> {:error, run.error}
      {:ok, _run} -> :ok
    end
  end

  defp to_integer(id) when is_integer(id), do: id
  defp to_integer(id) when is_binary(id), do: String.to_integer(id)
end
