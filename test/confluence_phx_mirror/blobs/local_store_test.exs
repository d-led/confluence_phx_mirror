defmodule ConfluencePhxMirror.Blobs.LocalStoreTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Blobs.LocalStore

  setup do
    root = Path.join(System.tmp_dir!(), "mirror-blob-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: [root: root]}
  end

  test "round-trips bytes under a nested key", %{root: root, opts: opts} do
    key = "spaces/ENG/pages/1/attachments/2/diagram.svg"

    assert {:ok, ^key} = LocalStore.put(key, "<svg/>", opts)
    assert {:ok, "<svg/>"} = LocalStore.read(key, opts)
    assert LocalStore.exists?(key, opts)
    assert {:ok, 6} = LocalStore.size(key, opts)
    assert File.exists?(Path.join(root, key))
  end

  test "overwrites an existing blob atomically", %{opts: opts} do
    key = "spaces/ENG/pages/1/attachments/2/notes.txt"

    assert {:ok, _} = LocalStore.put(key, "v1", opts)
    assert {:ok, _} = LocalStore.put(key, "v2", opts)
    assert {:ok, "v2"} = LocalStore.read(key, opts)
  end

  test "delete is idempotent", %{opts: opts} do
    key = "spaces/ENG/pages/1/attachments/2/notes.txt"

    assert {:ok, _} = LocalStore.put(key, "data", opts)
    assert :ok = LocalStore.delete(key, opts)
    assert :ok = LocalStore.delete(key, opts)
    refute LocalStore.exists?(key, opts)
  end

  test "rejects keys that escape the root", %{opts: opts} do
    assert {:error, :path_traversal} = LocalStore.put("../evil.txt", "x", opts)
    assert {:error, :absolute_key} = LocalStore.put("/etc/passwd", "x", opts)
    assert {:error, :empty_key} = LocalStore.put("", "x", opts)
  end

  test "missing blobs read as an error and exist? is false", %{opts: opts} do
    assert {:error, :enoent} = LocalStore.read("spaces/ENG/missing.txt", opts)
    refute LocalStore.exists?("spaces/ENG/missing.txt", opts)
  end
end
