defmodule ConfluencePhxMirror.Desktop.Credentials.Keyring do
  @moduledoc """
  The operating system's credential store, through the `keyring` crate in
  `native/confluence_keyring`.

  One implementation for all three platforms: the Apple Keychain on macOS,
  Credential Manager on Windows, and the Secret Service on Linux. The platform is
  chosen when the crate is compiled, so no run-time branch decides it.

  This replaces shelling out to `security` on macOS for two reasons. It covers
  the other two platforms, and the secret is handed to the OS directly instead of
  appearing in this process's arguments for the duration of a command.
  """

  @behaviour ConfluencePhxMirror.Desktop.Credentials

  use Rustler, otp_app: :confluence_phx_mirror, crate: :confluence_keyring

  # One service for everything this tool stores; the account is the site the
  # token belongs to (`Desktop.Settings.account/1`). The service name is what a
  # person sees in Keychain Access, so it says what made it.
  @service "confluence-export"

  @impl true
  def put(id, secret) when is_binary(id) and is_binary(secret) do
    # Rustler wraps every `Result` as `{:ok, value}` / `{:error, message}`, so
    # success is `{:ok, _}` whatever the value is.
    case put_password(@service, id, secret) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:keyring, reason}}
    end
  end

  @impl true
  def fetch(id) when is_binary(id) do
    case get_password(@service, id) do
      # Never stored: an ordinary answer, not a failure.
      {:ok, nil} -> {:error, :not_found}
      {:ok, secret} -> {:ok, secret}
      {:error, reason} -> {:error, {:keyring, reason}}
    end
  end

  @impl true
  def delete(id) when is_binary(id) do
    case delete_password(@service, id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:keyring, reason}}
    end
  end

  # Replaced from the crate when the NIF loads. A body that raises is what makes
  # a missing or unbuilt binary say so plainly instead of returning nil. Public
  # because that is what `:erlang.load_nif/2` replaces — a private function
  # cannot be exported and so can never be replaced.
  def put_password(_service, _account, _secret), do: :erlang.nif_error(:nif_not_loaded)

  def get_password(_service, _account), do: :erlang.nif_error(:nif_not_loaded)

  def delete_password(_service, _account), do: :erlang.nif_error(:nif_not_loaded)
end
