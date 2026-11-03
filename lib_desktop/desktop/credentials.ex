defmodule ConfluencePhxMirror.Desktop.Credentials do
  @moduledoc """
  Where a workspace's secret is kept: the operating system's credential store,
  never a file next to the data.

  A token in `settings.json` is a token in whatever backup, sync folder or
  `~/Dropbox` that file ends up in, readable by anything that can read the file.
  The OS store exists to avoid exactly that: macOS keeps the item in the login
  keychain, Windows in Credential Manager, Linux in the Secret Service, and all
  three encrypt it at rest under the user's own account.

  An entry is identified by a *service* and an *account*. The service is this
  application; the account is a constant — one tool on one machine is one
  workspace — so a lost settings file cannot lose the token with it.

  Implementations are chosen by `:desktop_credentials` in the application
  environment: `Keyring` (the default) and `Memory` (the suite).
  """

  @type id :: String.t()
  @type secret :: String.t()

  @callback put(id(), secret()) :: :ok | {:error, term()}
  @callback fetch(id()) :: {:ok, secret()} | {:error, :not_found | term()}
  @callback delete(id()) :: :ok | {:error, term()}

  @doc "Stores `secret` for the workspace `id`, replacing any earlier one."
  @spec put(id(), secret()) :: :ok | {:error, term()}
  def put(id, secret), do: impl().put(id, secret)

  @doc "The secret stored for `id`."
  @spec fetch(id()) :: {:ok, secret()} | {:error, :not_found | term()}
  def fetch(id), do: impl().fetch(id)

  @doc "Forgets the secret stored for `id`. A missing entry is not an error."
  @spec delete(id()) :: :ok | {:error, term()}
  def delete(id), do: impl().delete(id)

  defp impl do
    Application.get_env(
      :confluence_phx_mirror,
      :desktop_credentials,
      ConfluencePhxMirror.Desktop.Credentials.Keyring
    )
  end
end
