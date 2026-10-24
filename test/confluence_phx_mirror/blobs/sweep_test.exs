defmodule ConfluencePhxMirror.Blobs.SweepTest do
  @moduledoc """
  A sweep frees what nothing points at and touches nothing else: a blob a row
  still names, or one so new that its row may not exist yet, stays.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.{LocalStore, Sweep}

  setup do
    root = Path.join(System.tmp_dir!(), "mirror-sweep-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: [root: root]}
  end

  test "an old blob nothing refers to is freed, and a referenced one is not", %{
    root: root,
    opts: opts
  } do
    attachment =
      attachment_fixture(page_fixture(space_fixture()), %{
        blob_key: "spaces/ENG/pages/1/attachments/1/keep.txt"
      })

    referenced = attachment.blob_key
    orphan = "spaces/ENG/pages/1/attachments/2/gone.svg"

    {:ok, ^referenced} = LocalStore.put(referenced, "keep me", opts)
    {:ok, ^orphan} = LocalStore.put(orphan, "orphan", opts)
    backdate(Path.join(root, referenced))
    backdate(Path.join(root, orphan))

    assert Sweep.orphans(opts) == [orphan]

    assert {:ok, %{deleted: 1}} = Sweep.sweep(opts)

    refute LocalStore.exists?(orphan, opts)
    assert LocalStore.exists?(referenced, opts)
  end

  test "a blob written a moment ago is left alone, because its row may be in flight", %{
    opts: opts
  } do
    {:ok, _key} = LocalStore.put("spaces/ENG/pages/1/attachments/3/fresh.svg", "fresh", opts)

    assert {:ok, %{deleted: 0}} = Sweep.sweep(opts)
  end

  test "a store nobody has written to yet is swept without complaint", %{opts: opts} do
    assert {:ok, %{deleted: 0, bytes: 0}} = Sweep.sweep(opts)
  end

  # The age limit is what stands between a sweep and a sync's half-finished
  # write, so the test can ask for it to be zero and see the blob go.
  test "an age limit of zero sweeps everything unreferenced", %{root: root, opts: opts} do
    {:ok, orphan} = LocalStore.put("spaces/ENG/pages/1/attachments/4/now.svg", "now", opts)
    backdate(Path.join(root, orphan))

    assert {:ok, %{deleted: 1}} = Sweep.sweep(Keyword.put(opts, :if_older_than, 0))
  end

  defp backdate(path) do
    long_ago = System.os_time(:second) - 3_600
    File.touch!(path, long_ago)
  end
end
