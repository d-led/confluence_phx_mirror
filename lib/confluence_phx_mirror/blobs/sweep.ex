defmodule ConfluencePhxMirror.Blobs.Sweep do
  @moduledoc """
  Frees the bytes nothing points at any more.

  Postgres holds attachment metadata and the bytes live in a store, and every
  path that removes a row already deletes its blob — a purge from the trash, a
  replaced space icon, an attachment whose bytes changed. What no path can clean
  up is the blob a crashed run wrote before it recorded the row: the metadata is
  gone, the file is not, and nothing will ever reference it again.

  A sweep reads what the store holds, subtracts what the database references
  (attachment bytes and space icons), and deletes the rest — but only what is
  older than `:if_older_than` seconds (ten minutes by default), because a sync
  writes a blob and *then* the row, and a sweep that ran in that gap would
  delete a file that was about to become live.
  """

  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Mirror.{Attachment, Space}
  alias ConfluencePhxMirror.Repo

  import Ecto.Query

  @default_age_seconds 600

  @doc """
  Deletes every unreferenced blob older than the age limit.

  Returns how many were deleted and how many bytes that freed.
  """
  @spec sweep(keyword()) :: {:ok, %{deleted: non_neg_integer(), bytes: non_neg_integer()}}
  def sweep(opts \\ []) do
    cutoff = System.os_time(:second) - Keyword.get(opts, :if_older_than, @default_age_seconds)
    referenced = MapSet.new(referenced_keys())

    {deleted, bytes} =
      orphans(opts, cutoff, referenced)
      |> Enum.reduce({0, 0}, fn {key, _written_at}, {count, bytes} ->
        size = stored_size(key, opts)

        case Store.delete(key, opts) do
          :ok -> {count + 1, bytes + size}
          # A sweep is housekeeping: one file it cannot remove must not stop it
          # from removing the rest.
          {:error, _reason} -> {count, bytes}
        end
      end)

    {:ok, %{deleted: deleted, bytes: bytes}}
  end

  @doc "The blobs a sweep would delete, without deleting them."
  @spec orphans(keyword()) :: [String.t()]
  def orphans(opts \\ []) do
    cutoff = System.os_time(:second) - Keyword.get(opts, :if_older_than, @default_age_seconds)

    orphans(opts, cutoff, MapSet.new(referenced_keys()))
    |> Enum.map(&elem(&1, 0))
  end

  defp orphans(opts, cutoff, referenced) do
    Store.list(opts)
    |> Enum.filter(fn {key, written_at} ->
      written_at < cutoff and not MapSet.member?(referenced, key)
    end)
  end

  @doc """
  Every blob key the database still refers to: attachment bytes and space
  icons. A key that no row names is what a sweep may delete.
  """
  @spec referenced_keys() :: [String.t()]
  def referenced_keys do
    attachments =
      from(a in Attachment, where: not is_nil(a.blob_key), select: a.blob_key)

    icons =
      from(s in Space, where: not is_nil(s.icon_blob_key), select: s.icon_blob_key)

    Repo.all(attachments) ++ Repo.all(icons)
  rescue
    # No schema yet (a fresh database, or a migration in progress): nothing is
    # referenced, and the caller's age limit is what protects a young store.
    error in Postgrex.Error ->
      if error.postgres.code == :undefined_table, do: [], else: reraise(error, __STACKTRACE__)
  end

  defp stored_size(key, opts) do
    case Store.size(key, opts) do
      {:ok, size} -> size
      {:error, _reason} -> 0
    end
  end
end
