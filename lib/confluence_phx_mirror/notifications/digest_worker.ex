defmodule ConfluencePhxMirror.Notifications.DigestWorker do
  @moduledoc """
  Sends the daily digest at the configured UTC hour.

  Enqueued hourly by Oban's cron plugin; the hour itself is configuration
  (`MIRROR_DIGEST_HOUR_UTC`), so the schedule can change without a redeploy.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias ConfluencePhxMirror.{Mail, Mailer}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.Email

  # A paused queue is not this job's failure: it comes back and looks again.
  # Nothing is lost — the rows it would have sent are still pending.
  @snooze_seconds 600

  @impl true
  def perform(_job) do
    cond do
      ConfluencePhxMirror.Settings.mail_paused?() -> {:snooze, @snooze_seconds}
      due_now?() -> send_digests()
      true -> :ok
    end
  end

  defp due_now? do
    DateTime.utc_now().hour == ConfluencePhxMirror.Settings.digest_hour_utc()
  end

  defp send_digests do
    Notifications.pending_digest()
    |> Enum.reduce_while(:ok, fn {user, notifications}, :ok ->
      case Mailer.send(Email.digest(user, notifications), Mail.Budget.key(:digest, user)) do
        {:ok, _} ->
          Enum.each(notifications, &Notifications.mark_delivered/1)
          {:cont, :ok}

        # One digest has identity — this reader, this day — so a retry after the
        # relay took it changes nothing.
        {:error, :already_sent} ->
          Enum.each(notifications, &Notifications.mark_delivered/1)
          {:cont, :ok}

        # Out of allowance: the rest of the day's digests are not this job's to
        # force, and nothing is lost — the rows stay pending for tomorrow.
        {:error, :spent, seconds} ->
          {:halt, {:snooze, seconds}}

        {:error, reason} ->
          Logger.warning("digest delivery failed", user: user.email, reason: inspect(reason))
          Enum.each(notifications, &Notifications.mark_failed(&1, reason))
          {:halt, {:error, reason}}
      end
    end)
  end
end
