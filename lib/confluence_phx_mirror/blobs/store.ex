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
