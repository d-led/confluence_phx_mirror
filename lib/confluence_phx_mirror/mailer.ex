defmodule ConfluencePhxMirror.Mailer do
  @moduledoc """
  Delivers mail through the server in force *now*.

  `use Swoosh.Mailer` resolves its configuration from the application
  environment when a message is handed to it, which is what lets a release be
  configured by `config/runtime.exs`. The same seam is what makes the mail
  server a setting: `configure/0` writes what an administrator stored over the
  deployment's `SMTP_*` values, so a corrected relay takes effect on the next
  message instead of on the next deploy.

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
  end
end
