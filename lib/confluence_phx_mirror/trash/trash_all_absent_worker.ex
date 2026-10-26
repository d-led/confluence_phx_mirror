defmodule ConfluencePhxMirror.Trash.TrashAllAbsentWorker do
  @moduledoc """
  Moves everything the check found missing to the trash, off the request.

  A check over a hundred thousand pages can mark tens of thousands of them, and a
  mirror that lost a hundred spaces has a hundred of them — a click per space is
  not an action anybody performs. This is the one-click version: the pages are
  already marked by the check, and the job moves all of them in one transaction
  (`Mirror.trash_all_absent/0`, three statements that never list the ids).

  It moves what is *marked*, never what it decides: an unmarked page is a page the
  site still names, and nothing here second-guesses that.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Trash

  @impl true
  def perform(%Oban.Job{args: args}) do
    trashed = Trash.trash_all_absent(actor(args))

    Logger.info("trashed #{trashed} pages the site no longer lists")

    :ok
  end

  # The decision was a person's, and the audit row is written long after their
  # click; it should say whose.
  defp actor(%{"asked_by" => email}) when is_binary(email) do
    {:system, "the missing-pages review, asked by #{email}"}
  end

  defp actor(_args), do: {:system, "the missing-pages review"}
end
