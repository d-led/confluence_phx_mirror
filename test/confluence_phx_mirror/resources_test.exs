defmodule ConfluencePhxMirror.ResourcesTest do
  @moduledoc """
  What the admin page says the mirror occupies: the bytes the blob store holds,
  and what the device under it has left.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Resources

  @tag :tmp_dir
  test "the mount holds every file under it, at any depth", %{tmp_dir: dir} do
    store(dir, "attachments/ENG/1001/diagram.svg", 1500)
    store(dir, "attachments/ENG/1001/architecture.csv", 500)
    store(dir, "spaces/ENG/icon.svg", 64)

    mount = Resources.measure(dir)

    assert mount.path == dir
    assert mount.used_bytes == 2064
    assert mount.files == 3
  end

  @tag :tmp_dir
  test "a store nobody has written to yet is empty, not an error", %{tmp_dir: dir} do
    mount = Resources.measure(Path.join(dir, "nothing/here/yet"))

    assert mount.used_bytes == 0
    assert mount.files == 0
  end

  @tag :tmp_dir
  test "the device's room is reported before the store's own directory exists", %{tmp_dir: dir} do
    mount = Resources.measure(Path.join(dir, "not/created/yet"))

    assert %{total_bytes: total, free_bytes: free, percent: percent, mount: mount_point} =
             mount.device

    assert total > 0
    assert free > 0 and free <= total
    assert percent in 0..100
    assert is_binary(mount_point) and mount_point != ""
  end

  @tag :tmp_dir
  test "a symlink is not a file the store wrote", %{tmp_dir: dir} do
    target = Path.join(dir, "elsewhere.bin")
    File.write!(target, :binary.copy("x", 4096))

    store = Path.join(dir, "store")
    File.mkdir_p!(store)
    File.ln_s!(target, Path.join(store, "link.bin"))

    assert %{used_bytes: 0, files: 0} = Resources.measure(store)
  end

  defp store(dir, path, bytes) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, :binary.copy("x", bytes))
  end
end
