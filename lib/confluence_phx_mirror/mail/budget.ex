defmodule ConfluencePhxMirror.Mail.Budget do
  @moduledoc """
  The provider's daily allowance, spent before it is overrun.

  A hosted relay sells a number of messages a day and refuses the rest, so the
  mirror counts what it hands over: every message takes a row in `mail_sends`,
  and a message is only handed over while the day's rows are fewer than the
  allowance (`mail.per_day`, three hundred by default — Brevo's free plan).

  ## One message, one row

  The row also *names* the message. `dedup_key` is unique among the rows that
  were not refused, so a job Oban retries after the provider already took the
  mail finds the first attempt's key and stays quiet. The guarantee is
  deliberately one-directional: a crash between taking the row and handing the
  message over can lose that one message, and can never duplicate another. A
  notification is worth less than the same notification twice.

  A *refused* row frees its key, because the message never went: the retry is a
  new attempt, not a duplicate. It keeps its place in the day's count, since a
  relay that failed after accepting the mail has still spent it.

  The day is UTC. A provider's window is a provider's business, and one honest
  boundary is better than a boundary that moves with the site's time zone.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mail.Send
  alias ConfluencePhxMirror.{Repo, Settings}

  @typedoc """
  Why a message was not handed over.

    * `:already_sent` — a row already carries this key: the message went, or an
      attempt at it is still in flight;
    * `:spent` — the day's allowance is used up, and the number is the seconds
      until there is more.
  """
  @type refusal :: {:error, :already_sent} | {:error, :spent, pos_integer()}

  @doc """
  Reserves the day's next message, or says why there is none.

  Called immediately before the message is handed to the relay, never earlier:
  a slot reserved and then forgotten is a message an hour of the day cannot use.
  """
  @spec claim(String.t() | nil) :: {:ok, Send.t()} | refusal()
  def claim(dedup_key) do
    case reserve(dedup_key) do
      %Send{} = row -> {:ok, row}
      nil -> explain(dedup_key)
    end
  end

  # One statement, so two nodes cannot both believe they took the last slot:
  # the row is inserted only if the day is still under its limit. The conflict
  # clause is the other half — a key that is already pending or sent inserts
  # nothing, which is what makes a retried job quiet instead of a second message.
  defp reserve(dedup_key) do
    case Repo.query!(
           """
           INSERT INTO mail_sends (dedup_key, day, state, inserted_at)
           SELECT $1, current_date, 'pending', now()
           WHERE (SELECT count(*) FROM mail_sends WHERE day = current_date) < $2
           ON CONFLICT (dedup_key) WHERE state <> 'failed' DO NOTHING
           RETURNING id, dedup_key, day, state, error, inserted_at
           """,
           [dedup_key, limit()]
         ) do
      %{num_rows: 1, rows: [[id, key, day, state, error, inserted_at]]} ->
        %Send{
          id: id,
          dedup_key: key,
          day: day,
          state: state,
          error: error,
          inserted_at: inserted_at
        }

      _nothing_inserted ->
        nil
    end
  end

  # Nothing was inserted for one of two reasons, and the caller acts on them
  # differently: one is "this message went already" and the other is "no room
  # until tomorrow".
  defp explain(dedup_key) do
    if dedup_key && known?(dedup_key),
      do: {:error, :already_sent},
      else: {:error, :spent, seconds_until_tomorrow()}
  end

  defp known?(dedup_key) do
    Repo.exists?(from s in Send, where: s.dedup_key == ^dedup_key and s.state != "failed")
  end

  @doc "Records that the relay took the message."
  @spec mark_sent(Send.t()) :: :ok
  def mark_sent(%Send{id: id}) do
    from(s in Send, where: s.id == ^id) |> Repo.update_all(set: [state: "sent", error: nil])
    :ok
  end

  @doc """
  Records that the message did not go, with what the relay said.

  The row keeps its place in the day's count — a relay that refused after
  accepting has still spent an allowance — but frees its key, so the retry is a
  new attempt rather than a duplicate.
  """
  @spec mark_failed(Send.t(), term()) :: :ok
  def mark_failed(%Send{id: id}, reason) do
    from(s in Send, where: s.id == ^id)
    |> Repo.update_all(set: [state: "failed", error: describe(reason)])

    :ok
  end

  @doc "How many messages the provider allows in one day."
  @spec limit() :: pos_integer()
  def limit, do: Settings.mail_per_day()

  @doc """
  The identity of a message, for the senders that have one to give.

  A watcher's notification is named by its own row; a digest by its reader and
  the day it covers, because one digest a day is the whole of what it is; a test
  message or a welcome by the person it is for. A message without an identity —
  anything sent once, by hand, for no one in particular — passes `nil`.
  """
  @spec key(ConfluencePhxMirror.Notifications.Notification.t()) :: String.t()
  @spec key(:digest | :welcome | :test, ConfluencePhxMirror.Accounts.User.t()) :: String.t()
  def key(%ConfluencePhxMirror.Notifications.Notification{id: id}), do: "notification:#{id}"

  def key(:digest, %ConfluencePhxMirror.Accounts.User{id: id}),
    do: "digest:#{id}:#{Date.utc_today()}"

  def key(:welcome, %ConfluencePhxMirror.Accounts.User{id: id}), do: "welcome:#{id}"

  # A reader asks for a test message; every ask is its own message. The
  # millisecond keeps two asks from carrying one name, which the ledger would
  # read as "this one went already" — the minute between them is a window the
  # caller measures (see `ConfluencePhxMirror.Mail.send_test/1`).
  def key(:test, %ConfluencePhxMirror.Accounts.User{id: id}),
    do: "test:#{id}:#{System.system_time(:millisecond)}"

  # A link is one event with two ends, and each end that has an address gets its
  # own message: the side names which one, so neither takes the other's name in
  # the ledger. The event's own moment keeps the key unique — the same identity
  # can be unlinked and linked again, and the second time is news too — while a
  # request that arrives twice finds the identity already linked and never gets
  # as far as a message.
  @spec key(
          :identity_link,
          ConfluencePhxMirror.Accounts.User.t(),
          String.t(),
          :account | :identity
        ) ::
          String.t()
  def key(:identity_link, %ConfluencePhxMirror.Accounts.User{id: id}, account_id, side),
    do: "identity_link:#{id}:#{account_id}:#{side}:#{System.system_time(:millisecond)}"

  @doc "How many messages have been handed over today, refusals included."
  @spec used() :: non_neg_integer()
  def used, do: Repo.aggregate(from(s in Send, where: s.day == ^Date.utc_today()), :count)

  @doc """
  How many messages have been handed over in all, refusals included.

  The same count `used/0` makes for one day, over every day the mirror has sent
  anything. A screen shows the pair, so "ever" can never be smaller than
  "today" — it counts the same rows, not another kind of them.
  """
  @spec handed_over() :: non_neg_integer()
  def handed_over, do: Repo.aggregate(Send, :count)

  @doc "What is left of today's allowance, for a screen that says so."
  @spec remaining() :: non_neg_integer()
  def remaining, do: max(limit() - used(), 0)

  @doc """
  When the last test message to `user` went, if one ever did.

  The minute between two of them is measured from here rather than from a
  clock bucket, so the answer does not depend on when in a minute the first one
  was sent. A refused attempt does not count: it never went.
  """
  @spec last_test_at(ConfluencePhxMirror.Accounts.User.t()) :: DateTime.t() | nil
  def last_test_at(%ConfluencePhxMirror.Accounts.User{id: id}) do
    Repo.one(
      from s in Send,
        where: like(s.dedup_key, ^"test:#{id}:%") and s.state != "failed",
        select: max(s.inserted_at)
    )
  end

  defp seconds_until_tomorrow do
    now = DateTime.utc_now()
    midnight = now |> DateTime.to_date() |> Date.add(1) |> DateTime.new!(~T[00:00:00])

    max(DateTime.diff(midnight, now, :second), 60)
  end

  defp describe(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 500)
end
