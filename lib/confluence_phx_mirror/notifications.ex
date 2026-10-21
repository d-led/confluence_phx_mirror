defmodule ConfluencePhxMirror.Notifications do
  @moduledoc """
  Subscriptions and e-mail notifications.

  Instant subscribers get one e-mail per changed page; daily subscribers get a
  digest. Every message is first written to the `notifications` outbox, which
  makes delivery auditable and retryable. E-mail is always sent through
  `ConfluencePhxMirror.Mailer` (smtp4dev in development).
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.User
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
      |> Enum.map(&notify_subscriber(&1, page, action))
      |> Enum.reject(&match?({:error, _}, &1))
    else
      []
    end
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

  defp enabled?,
    do:
      Application.get_env(:confluence_phx_mirror, :notifications, [])
      |> Keyword.get(:enabled, true)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
