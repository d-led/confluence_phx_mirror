defmodule ConfluencePhxMirror.Mailer do
  @moduledoc """
  Delivers mail through the server in force *now*.

  `use Swoosh.Mailer` resolves its configuration from the application
  environment when a message is handed to it, which is what lets a release be
  configured by `config/runtime.exs`. The same seam is what makes the mail
  server a setting: `configure/0` writes what an administrator stored over the
  deployment's `SMTP_*` values, so a corrected relay takes effect on the next
  message instead of on the next deploy.

  The sender is part of that configuration, and it is published twice on
  purpose: the settings own it, and `:notifications, :from` is where every
  message builder already reads it. A message therefore cannot disagree with
  the mail server screen about who it is from — the builders written against
  that key before the screen could change it included.

  With no relay at all — stored or configured — the deployment keeps Swoosh's
  Local adapter and mail is written to a file rather than sent, exactly as
  before. A test suite keeps its own adapter: `configure/0` is not called there.
  """

  use Swoosh.Mailer, otp_app: :confluence_phx_mirror

  alias ConfluencePhxMirror.Audit

  @doc """
  Rebuilds the adapter configuration from what the settings say.

  Called at boot (after the settings are loaded) and after every save, so the
  screen and the sender never disagree.
  """
  @spec configure() :: :ok
  def configure do
    Application.put_env(
      :confluence_phx_mirror,
      __MODULE__,
      ConfluencePhxMirror.Settings.mail_configuration()
    )

    publish_sender()
    :ok
  end

  @doc """
  Who mail is from: the stored sender, else the deployment's.

  A message written here takes its `from` from this. It is the same pair the
  builders that read `:notifications, :from` get, because `configure/0` writes
  it there as well.
  """
  @spec sender() :: {String.t(), String.t()}
  def sender, do: ConfluencePhxMirror.Settings.mail_sender()

  @doc """
  Hands one message to the relay, if the day has room for it.

  Every sender goes through here rather than `deliver/1`, so that the provider's
  allowance is spent by counting rather than by being refused (see
  `ConfluencePhxMirror.Mail.Budget`). `dedup_key` names the message: a retry
  that carries the key of a message already sent is refused as `:already_sent`,
  and a message with no identity passes `nil`.

  Answers `{:error, :spent, seconds}` when the allowance is gone — a caller with
  a queue behind it snoozes for that long instead of failing, and a message
  somebody is waiting on says so.

  `actor` is who asked for it, and every attempt is in the audit trail — sent,
  refused, or taken by the relay and refused by it. A mirror's mail is the one
  thing it does that leaves the building, and "who wrote to whom" is a question
  an audit has to answer without asking a provider.
  """
  @spec send(Swoosh.Email.t(), String.t() | nil, Audit.actor()) ::
          {:ok, term()}
          | ConfluencePhxMirror.Mail.Budget.refusal()
          | {:error, term()}
  def send(email, dedup_key, actor \\ Audit.system_actor()) do
    case ConfluencePhxMirror.Mail.Budget.claim(dedup_key) do
      {:ok, send} -> send_now(email, send, dedup_key, actor)
      {:error, :spent, seconds} -> refuse_spent(dedup_key, seconds, actor)
      {:error, reason} -> refuse(reason, dedup_key, actor)
    end
  end

  defp send_now(email, send, dedup_key, actor) do
    case deliver(email) do
      {:ok, receipt} ->
        ConfluencePhxMirror.Mail.Budget.mark_sent(send)
        Audit.log(actor, message_entry("mail.sent", email, dedup_key))
        {:ok, receipt}

      {:error, reason} ->
        ConfluencePhxMirror.Mail.Budget.mark_failed(send, reason)

        Audit.log(
          actor,
          message_entry("mail.failed", email, dedup_key, %{"error" => inspect(reason)})
        )

        {:error, reason}
    end
  end

  # Nothing left the node, and that is worth a line too: a queue that silently
  # stopped is indistinguishable from a quiet week.
  defp refuse_spent(dedup_key, seconds, actor) do
    Audit.log(actor, message_entry("mail.not_sent", nil, dedup_key, %{"reason" => "spent"}))

    {:error, :spent, seconds}
  end

  defp refuse(reason, dedup_key, actor) do
    Audit.log(
      actor,
      message_entry("mail.not_sent", nil, dedup_key, %{"reason" => to_string(reason)})
    )

    {:error, reason}
  end

  defp message_entry(action, email, dedup_key, extra \\ %{}) do
    Audit.Entry.new(
      action,
      "message",
      dedup_key || "one-off",
      Map.merge(
        %{"kind" => kind(dedup_key), "to" => recipient(email), "subject" => subject(email)},
        extra
      )
    )
  end

  # The key's own word is what the message is: a notification, a digest, a
  # welcome, a test. Without a key there is no identity to read, and the audit
  # says so.
  defp kind(nil), do: "one-off"
  defp kind(dedup_key), do: dedup_key |> String.split(":") |> List.first()

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address
  defp recipient(%Swoosh.Email{to: [address | _]}), do: to_string(address)
  defp recipient(_email), do: nil

  defp subject(%Swoosh.Email{subject: subject}), do: subject
  defp subject(_email), do: nil

  defp publish_sender do
    notifications = Application.get_env(:confluence_phx_mirror, :notifications, [])

    Application.put_env(
      :confluence_phx_mirror,
      :notifications,
      Keyword.put(notifications, :from, sender())
    )
  end
end
