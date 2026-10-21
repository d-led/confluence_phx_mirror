defmodule ConfluencePhxMirror.Notifications.EmailWorker do
  @moduledoc """
  Sends one instant notification. Retries are handled by Oban, and failures are
  recorded on the notification row so the admin dashboard shows them.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 5, unique: [period: 300]

  alias ConfluencePhxMirror.Mailer
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.Email
  alias ConfluencePhxMirror.Notifications.Notification

  @impl true
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    notification =
      ConfluencePhxMirror.Repo.get!(Notification, notification_id)
      |> ConfluencePhxMirror.Repo.preload(:user)

    if notification.delivered_at do
      :ok
    else
      case Mailer.deliver(Email.page_updated(notification, notification.user)) do
        {:ok, _} ->
          Notifications.mark_delivered(notification)
          :ok

        {:error, reason} ->
          Notifications.mark_failed(notification, reason)
          {:error, reason}
      end
    end
  end
end
