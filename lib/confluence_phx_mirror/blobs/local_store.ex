defmodule ConfluencePhxMirror.Blobs.LocalStore do
  @moduledoc """
  Filesystem implementation of `ConfluencePhxMirror.Blobs.Store`.

  Writes are atomic (temporary file + rename), so a crashed sync can never
  leave a half-written attachment behind. Keys are validated again here: a
  key containing `..` or an absolute path is rejected even if a caller built it
  by hand.
  """
  @behaviour ConfluencePhxMirror.Blobs.Store

  @impl true
  def put(key, data, opts) when is_binary(data) do
    with :ok <- validate_key(key),
         path = absolute_path(key, opts),
         :ok <- File.mkdir_p(Path.dirname(path)),
         tmp = path <> ".tmp-#{System.unique_integer([:positive])}",
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, path) do
      {:ok, key}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def read(key, opts) do
    with :ok <- validate_key(key) do
      File.read(absolute_path(key, opts))
    end
  end

  @impl true
  def delete(key, opts) do
    with :ok <- validate_key(key) do
      case File.rm(absolute_path(key, opts)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def exists?(key, opts) do
    with :ok <- validate_key(key) do
      File.regular?(absolute_path(key, opts))
    else
      _ -> false
    end
  end

  @impl true
  def size(key, opts) do
    with :ok <- validate_key(key),
         {:ok, %File.Stat{size: size}} <- File.stat(absolute_path(key, opts)) do
      {:ok, size}
    end
  end

  @impl true
  def root(opts) do
    root =
      Keyword.get(opts, :root) ||
        Application.get_env(:confluence_phx_mirror, :blob_root, "priv/static/mirror")

    case Path.type(root) do
      :absolute -> Path.expand(root)
      :relative -> Path.expand(root, File.cwd!())
    end
  end

  @doc "Absolute filesystem path of `key`, guaranteed to stay under the root."
  def absolute_path(key, opts \\ []) do
    root = root(opts)
    path = Path.expand(Path.join(root, key))

    unless String.starts_with?(path, root <> "/") do
      raise ArgumentError, "blob key escapes the store root: #{inspect(key)}"
    end

    path
  end

  defp validate_key(key) when is_binary(key) do
    cond do
      key == "" -> {:error, :empty_key}
      Path.type(key) == :absolute -> {:error, :absolute_key}
      ".." in Path.split(key) -> {:error, :path_traversal}
      true -> :ok
    end
  end

  defp validate_key(_key), do: {:error, :invalid_key}
end
