defmodule ConfluencePhxMirror.FailingMailer do
  @moduledoc """
  A mailer adapter that always refuses.

  The digest worker has a branch for a refused delivery — record the reason on
  every entry and let the job fail so Oban retries — and nothing else in the
  suite can reach it, because the test adapter never fails.
  """

  @behaviour Swoosh.Adapter

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def deliver(_email, _config), do: {:error, :smtp_down}
end
