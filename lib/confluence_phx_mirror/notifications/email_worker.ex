defmodule ConfluencePhxMirror.Notifications.EmailWorker do
  @moduledoc """
  Sends a reader everything that changed for them, once a burst is over.

  A sync changes a hundred pages at once, and a reader watching a space would
  otherwise get a hundred messages for one morning's work — a hundred of their
  attention and a hundred of the provider's daily allowance, which is three
  hundred (see `ConfluencePhxMirror.Mail.Budget`). Confluence debounces the same
  way, and so does this.

  ## One job per reader, not per change

  The first change for a reader schedules a send one window later
  (`notifications.window_seconds`). Every change that arrives meanwhile joins the
  job already waiting, because the job is unique per reader while it is
  incomplete — so a burst costs one job and one message, and the window is
  measured from the *first* change: a site that changes something every minute
  still mails on time instead of waiting for quiet.

  What the message contains is whatever is still pending when it runs, so it
  cannot lose a change that arrived while it was being scheduled, and it cannot
  repeat one it already sent: delivery marks the rows.

  A paused queue is not a failure, and neither is a spent daily allowance — the
  job snoozes and the rows wait, which is the whole point of keeping them. A row
  that is gone (an operator purged the queue) is done, not an error.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:args, :worker, :queue], states: :incomplete]

  require Logger

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.{Mailer, Settings}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.Email

  @snooze_seconds 60

  @doc """
  Asks for a send to this reader, a window from now.

  A reader who already has one waiting keeps it — the insert comes back as a
  conflict — so the cost of a burst is one job however many changes it carried.
  """
  @spec schedule(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(user_id) do
    %{"user_id" => user_id}
    |> new(scheduled_at: DateTime.add(DateTime.utc_now(), window(), :second))
    |> Oban.insert()
  end

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    if Settings.mail_paused?() do
      {:snooze, @snooze_seconds}
    else
      send_pending(user_id)
    end
  end

  # The oldest row of the batch names the message, so a retry of the same burst
  # carries the same key and the ledger refuses to send it twice.
  defp send_pending(user_id) do
    case Notifications.pending_for(user_id) do
      [] -> :ok
      [first | _rest] = notifications -> deliver(first.user, notifications, first.id)
    end
  end

  defp deliver(%User{} = user, notifications, batch_id) do
    case Mailer.send(Email.updates(user, notifications), "updates:#{user.id}:#{batch_id}") do
      {:ok, _} ->
        mark(notifications, &Notifications.mark_delivered/1)
        :ok

      {:error, :spent, seconds} ->
        {:snooze, seconds}

      {:error, :already_sent} ->
        mark(notifications, &Notifications.mark_delivered/1)
        :ok

      {:error, reason} ->
        mark(notifications, &Notifications.mark_failed(&1, reason))
        Logger.warning("notification delivery failed", user: user.email, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp mark(notifications, change), do: Enum.each(notifications, change)

  # One second is "send each change as it comes" — the window in which a burst is
  # collected is measured in whole seconds, and a reader who wants no batching at
  # all gets one message per change per second, which is what the queue did
  # before it could batch.
  defp window, do: Settings.notification_window_seconds()
end
