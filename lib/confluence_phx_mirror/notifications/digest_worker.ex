defmodule ConfluencePhxMirror.Notifications.DigestWorker do
  @moduledoc """
  Sends the daily digest at the configured UTC hour.

  Enqueued hourly by Oban's cron plugin; the hour itself is configuration
  (`MIRROR_DIGEST_HOUR_UTC`), so the schedule can change without a redeploy.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias ConfluencePhxMirror.Mailer
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.Email

  @impl true
  def perform(_job) do
    if due_now?() do
      send_digests()
    else
      :ok
    end
  end

  defp due_now? do
    DateTime.utc_now().hour == ConfluencePhxMirror.Settings.digest_hour_utc()
  end

  defp send_digests do
    Notifications.pending_digest()
    |> Enum.reduce_while(:ok, fn {user, notifications}, :ok ->
      case Mailer.deliver(Email.digest(user, notifications)) do
        {:ok, _} ->
          Enum.each(notifications, &Notifications.mark_delivered/1)
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("digest delivery failed", user: user.email, reason: inspect(reason))
          Enum.each(notifications, &Notifications.mark_failed(&1, reason))
          {:halt, {:error, reason}}
      end
    end)
  end
end
