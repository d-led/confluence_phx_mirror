defmodule ConfluencePhxMirror.Blobs.Store do
  @moduledoc """
  Path-based blob storage for attachment bytes.

  Postgres stores attachment *metadata* only. The bytes live behind this
  behaviour, addressed by a meaningful, human-readable key:

      spaces/ENG/pages/12345/attachments/67890/architecture-diagram.svg

  `ConfluencePhxMirror.Blobs.LocalStore` is the default implementation; a
  future S3 implementation only has to implement this behaviour.
  """

  @type key :: String.t()

  @callback put(key(), binary(), keyword()) :: {:ok, key()} | {:error, term()}
  @callback read(key(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback delete(key(), keyword()) :: :ok | {:error, term()}
  @callback exists?(key(), keyword()) :: boolean()
  @callback size(key(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback root(keyword()) :: Path.t()

  @doc """
  Every blob the store holds, with the second it was last written.

  Only a store that can enumerate its bytes can be swept for orphans, so this
  is optional: a store that cannot answer leaves it out, and nothing is ever
  deleted on a guess.
  """
  @callback list(keyword()) :: [{key(), non_neg_integer()}]

  @optional_callbacks list: 1

  @doc "Stores `data` under `key`, creating parent directories as needed."
  def put(key, data, opts \\ []), do: impl().put(key, data, opts)

  @doc "Reads the bytes stored under `key`."
  def read(key, opts \\ []), do: impl().read(key, opts)

  @doc "Removes the blob stored under `key`. Missing blobs are not an error."
  def delete(key, opts \\ []), do: impl().delete(key, opts)

  @doc "Whether a blob exists under `key`."
  def exists?(key, opts \\ []), do: impl().exists?(key, opts)

  @doc "Size of the blob in bytes."
  def size(key, opts \\ []), do: impl().size(key, opts)

  @doc """
  Every blob the store holds, with the second it was last written.

  Answered only by a store that can enumerate (`c:list/1`); a store that cannot
  raises, because a caller that wants a sweep must not be told "nothing here".
  """
  def list(opts \\ []) do
    module = impl()
    Code.ensure_loaded?(module)

    if function_exported?(module, :list, 1) do
      module.list(opts)
    else
      raise "#{inspect(module)} cannot list its blobs, so it cannot be swept"
    end
  end

  @doc "Absolute root directory of the store."
  def root(opts \\ []), do: impl().root(opts)

  defp impl,
    do:
      Application.get_env(
        :confluence_phx_mirror,
        :blob_store,
        ConfluencePhxMirror.Blobs.LocalStore
      )
end
