defmodule ConfluencePhxMirror.Desktop.Credentials.Memory do
  @moduledoc """
  A credential store that holds nothing but what the current test put there.

  It exists so the suite never touches the login keychain: a test that writes to
  the real store leaves an item behind on a developer's machine, and asks for
  access to it on somebody else's.
  """

  @behaviour ConfluencePhxMirror.Desktop.Credentials

  @impl true
  def put(id, secret) when is_binary(id) and is_binary(secret) do
    :persistent_term.put({__MODULE__, id}, secret)
    :ok
  end

  @impl true
  def fetch(id) when is_binary(id) do
    case :persistent_term.get({__MODULE__, id}, nil) do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  @impl true
  def delete(id) when is_binary(id) do
    :persistent_term.erase({__MODULE__, id})
    :ok
  end
end
