defmodule ConfluencePhxMirror.Notifications do
  @moduledoc """
  Subscriptions and e-mail notifications.

  Instant subscribers get one e-mail per changed page; daily subscribers get a
  digest. Every message is first written to the `notifications` outbox, which
  makes delivery auditable and retryable. E-mail is always sent through
  `ConfluencePhxMirror.Mailer` (smtp4dev in development).
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.{Scope, User}
  alias ConfluencePhxMirror.{Audit, Authorization}
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Notifications.{Notification, Subscription}
  alias ConfluencePhxMirror.Repo

  @doc "Subscribes a user to a page or a space."
  def subscribe(%User{} = user, target_type, target_id, frequency \\ "instant") do
    %Subscription{}
    |> Subscription.changeset(%{
      user_id: user.id,
      target_type: target_type,
      target_id: target_id,
      frequency: frequency
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :target_type, :target_id])
  end

  def unsubscribe(%User{} = user, target_type, target_id) do
    from(s in Subscription,
      where:
        s.user_id == ^user.id and s.target_type == ^target_type and
          s.target_id == ^target_id
    )
    |> Repo.delete_all()

    :ok
  end

  def subscribed?(%User{} = user, target_type, target_id) do
    Repo.exists?(
      from s in Subscription,
        where:
          s.user_id == ^user.id and s.target_type == ^target_type and
            s.target_id == ^target_id
    )
  end

  @doc """
  Which of `targets` — `{type, id}` pairs — the user watches.

  A page view asks about the page and its space in one go: two questions with
  the same shape, and one subscription row answers both.
  """
  @spec watching(User.t(), [{String.t(), integer()}]) :: MapSet.t({String.t(), integer()})
  def watching(%User{} = user, targets) do
    types = Enum.map(targets, &elem(&1, 0))
    ids = Enum.map(targets, &elem(&1, 1))

    from(s in Subscription,
      where: s.user_id == ^user.id and s.target_type in ^types and s.target_id in ^ids,
      select: {s.target_type, s.target_id}
    )
    |> Repo.all()
    |> MapSet.new()
    # A page and a space can share a number; only the pairs asked about count.
    |> MapSet.intersection(MapSet.new(targets))
  end

  def subscriptions(%User{id: user_id}) do
    Repo.all(from s in Subscription, where: s.user_id == ^user_id, order_by: [asc: s.inserted_at])
  end

  @doc """
  Creates notification rows for everyone watching the page or its space.

  Instant subscribers are enqueued right away; daily subscribers are picked up
  by `ConfluencePhxMirror.Notifications.DigestWorker`.
  """
  def page_changed(%Page{} = page, action) do
    if enabled?() do
      page
      |> subscribers()
      |> Enum.filter(&may_read?(&1.user, page))
      |> Enum.map(&notify_subscriber(&1, page, action))
      |> Enum.reject(&match?({:error, _}, &1))
    else
      []
    end
  end

  # A subscription is what the reader asked for; whether they may read the page
  # is still decided here, from the permissions as they stand at delivery time.
  # A page that became restricted, or a reader who lost a group, stops getting
  # its title by e-mail.
  defp may_read?(%User{} = user, page) do
    Authorization.can_read_page?(Scope.for_user(user), page)
  end

  defp subscribers(page) do
    from(s in Subscription,
      join: u in assoc(s, :user),
      where:
        (s.target_type == "page" and s.target_id == ^page.id) or
          (s.target_type == "space" and s.target_id == ^page.space_id),
      preload: [user: u]
    )
    |> Repo.all()
  end

  defp notify_subscriber(subscription, page, action) do
    subject = notification_subject(page, action)
    body = notification_body(page, action)

    attrs = %{
      user_id: subscription.user_id,
      page_id: page.id,
      kind: "page_updated",
      subject: subject,
      body: body
    }

    with {:ok, notification} <- %Notification{} |> Notification.changeset(attrs) |> Repo.insert(),
         {:ok, _job} <- enqueue(notification, subscription.frequency) do
      {:ok, notification}
    end
  end

  defp enqueue(notification, "instant") do
    %{"notification_id" => notification.id}
    |> ConfluencePhxMirror.Notifications.EmailWorker.new()
    |> Oban.insert()
  end

  defp enqueue(_notification, "daily"), do: {:ok, :deferred_to_digest}

  @doc "Subject line shared by instant and digest e-mails."
  def notification_subject(page, action) do
    verb =
      case action do
        :created -> "added"
        :updated -> "updated"
        :deleted -> "removed"
        _ -> "changed"
      end

    "[Mirror] #{page.space.key}: #{page.title} #{verb}"
  end

  @doc "Plain-text body shared by instant and digest e-mails."
  def notification_body(page, action) do
    path =
      ConfluencePhxMirror.Mirror.URLs.page_path(page.space.key, page.confluence_id, page.slug)

    verb = if action == :created, do: "was added to", else: "was updated in"

    """
    #{page.title} #{verb} the mirror.

    Read it here: #{path}
    Original: #{page.external_url}
    Version: #{page.version_number}
    """
  end

  @doc "Marks an instant notification as delivered."
  def mark_delivered(%Notification{} = notification) do
    notification
    |> Ecto.Changeset.change(
      delivered_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil
    )
    |> Repo.update()
  end

  @doc "Records a delivery error so the failure is visible in the admin UI."
  def mark_failed(%Notification{} = notification, reason) do
    notification
    |> Ecto.Changeset.change(error: format_error(reason))
    |> Repo.update()
  end

  @doc "Unsent daily notifications, grouped for the digest."
  def pending_digest do
    from(n in Notification,
      where: is_nil(n.delivered_at) and is_nil(n.error),
      join: u in assoc(n, :user),
      preload: [user: u],
      order_by: [asc: n.inserted_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.user)
  end

  def recent(limit \\ 50) do
    from(n in Notification,
      join: u in assoc(n, :user),
      preload: [user: u],
      order_by: [desc: n.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  What is still to go out: every notification without a delivery, oldest first.

  A row is in this list because nobody has sent it yet — waiting for its turn,
  waiting for a paused queue to resume, or waiting for its next attempt after
  the relay refused it. `error` says which of those it is.
  """
  @spec queue(keyword()) :: [Notification.t()]
  def queue(opts \\ []) do
    from(n in Notification,
      where: is_nil(n.delivered_at),
      join: u in assoc(n, :user),
      preload: [user: u],
      order_by: [asc: n.inserted_at],
      limit: ^Keyword.get(opts, :limit, 100)
    )
    |> Repo.all()
  end

  @doc """
  How the outbox stands: waiting, refused, delivered.

  `delivered` is what the mirror has ever sent, which is the number an operator
  wants after a purge — "the history is still there, the queue is not".
  """
  @spec counts() :: %{
          queued: non_neg_integer(),
          failed: non_neg_integer(),
          delivered: non_neg_integer()
        }
  def counts do
    waiting = from(n in Notification, where: is_nil(n.delivered_at))

    %{
      queued: waiting |> where([n], is_nil(n.error)) |> Repo.aggregate(:count),
      failed: waiting |> where([n], not is_nil(n.error)) |> Repo.aggregate(:count),
      delivered:
        from(n in Notification, where: not is_nil(n.delivered_at))
        |> Repo.aggregate(:count)
    }
  end

  @doc """
  Recently delivered notifications, newest first.

  The history a purge leaves alone: what was sent, and when. One screen reads it
  to keep "the queue is empty" from looking like "mail never ran".
  """
  @spec delivered(pos_integer()) :: [Notification.t()]
  def delivered(limit \\ 10) do
    from(n in Notification,
      where: not is_nil(n.delivered_at),
      join: u in assoc(n, :user),
      preload: [user: u],
      order_by: [desc: n.delivered_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Drops everything that has not been delivered, and the jobs that would send it.

  The queue is what an operator purges when it was built while something was
  wrong — a relay that sent to the wrong people, a sync that announced pages
  nobody wanted. Delivered rows are the history and stay. So do the jobs:
  cancelling them first is what keeps a purged row from failing a delivery, and
  a worker that finds its row gone treats that as done.
  """
  @spec purge_queue(Audit.actor()) :: {:ok, non_neg_integer()}
  def purge_queue(actor) do
    {:ok, cancelled} = cancel_queued_deliveries()

    {deleted, _} =
      from(n in Notification, where: is_nil(n.delivered_at))
      |> Repo.delete_all()

    Audit.log(
      actor,
      Audit.Entry.new("mail.queue_purged", "notification", "queue", %{
        "deleted" => deleted,
        "cancelled_jobs" => cancelled
      })
    )

    {:ok, deleted}
  end

  # Oban holds a delivery per instant notification. One that is `executing` is
  # left alone: its worker is running right now and the purge may still find an
  # undelivered row, which is the row the worker has open.
  defp cancel_queued_deliveries do
    from(j in Oban.Job,
      where: j.queue == "notifications" and j.state in ~w(available scheduled retryable)
    )
    |> Oban.cancel_all_jobs()
  end

  defp enabled?, do: ConfluencePhxMirror.Settings.notifications_enabled?()

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
