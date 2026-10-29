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

  defp publish_sender do
    notifications = Application.get_env(:confluence_phx_mirror, :notifications, [])

    Application.put_env(
      :confluence_phx_mirror,
      :notifications,
      Keyword.put(notifications, :from, sender())
    )
  end
end
