defmodule ConfluencePhxMirror.Notifications.EmailWorker do
  @moduledoc """
  Sends one instant notification. Retries are handled by Oban, and failures are
  recorded on the notification row so the admin dashboard shows them.

  A paused mail queue is not a failure: the job snoozes and the row stays where
  it is, so a resume sends what was waiting instead of losing it. A row that is
  gone (an operator purged the queue) is done, not an error. The same goes for a
  day whose provider allowance is spent: the message waits for the room rather
  than failing, because a refused send is a notification the reader never gets.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 5, unique: [period: 300]

  alias ConfluencePhxMirror.{Mail, Mailer, Repo, Settings}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.{Email, Notification}

  @snooze_seconds 60

  @impl true
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    if Settings.mail_paused?() do
      {:snooze, @snooze_seconds}
    else
      deliver(notification_id)
    end
  end

  defp deliver(notification_id) do
    case Repo.get(Notification, notification_id) do
      nil ->
        :ok

      %Notification{delivered_at: %DateTime{}} ->
        :ok

      %Notification{} = notification ->
        notification = Repo.preload(notification, :user)

        case Mailer.send(
               Email.page_updated(notification, notification.user),
               Mail.Budget.key(notification)
             ) do
          {:ok, _} ->
            Notifications.mark_delivered(notification)
            :ok

          # The day's allowance is gone. Nothing is lost: the row is still
          # pending and the job comes back when the provider has room.
          {:error, :spent, seconds} ->
            {:snooze, seconds}

          # Either this message went and the row was never marked, or another
          # attempt at it is in flight. Both mean nobody needs sending again.
          {:error, :already_sent} ->
            Notifications.mark_delivered(notification)
            :ok

          {:error, reason} ->
            Notifications.mark_failed(notification, reason)
            {:error, reason}
        end
    end
  end
end
