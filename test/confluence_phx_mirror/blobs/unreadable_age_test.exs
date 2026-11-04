defmodule ConfluencePhxMirror.Blobs.UnreadableAgeTest do
  @moduledoc """
  A sweep deletes by age, so a blob whose age cannot be read is not a blob of
  age zero — it is a question the sweep cannot answer, and the answer it must
  give is "leave it". A store reports `:unknown` for exactly that.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Blobs.Sweep

  # A store that holds one blob and cannot say when it was written. Nothing in
  # the database points at it, and it would look very old if `:unknown` were
  # read as a number.
  defmodule UndateableStore do
    @moduledoc false
    @behaviour ConfluencePhxMirror.Blobs.Store

    def put(_key, _data, _opts), do: {:ok, "a"}
    def read(_key, _opts), do: {:error, :enoent}
    def size(_key, _opts), do: {:ok, 42}
    def exists?(_key, _opts), do: true
    def root(_opts), do: System.tmp_dir!()
    def list(_opts), do: [{"spaces/ENG/pages/1/attachments/9/gone.svg", :unknown}]

    def delete(key, _opts) do
      send(:persistent_term.get({__MODULE__, :test_process}), {:deleted, key})
      :ok
    end
  end

  setup do
    :persistent_term.put({UndateableStore, :test_process}, self())
    on_exit(fn -> :persistent_term.erase({UndateableStore, :test_process}) end)

    ConfluencePhxMirror.TestConfig.put(:blob_store, UndateableStore)

    :ok
  end

  test "a blob whose age cannot be read is not a candidate" do
    assert Sweep.orphans() == []

    assert {:ok, %{deleted: 0, bytes: 0}} = Sweep.sweep()

    refute_received {:deleted, _anything}
  end
end
