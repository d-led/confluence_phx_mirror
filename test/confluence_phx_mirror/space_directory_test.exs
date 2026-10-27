defmodule ConfluencePhxMirror.SpaceDirectoryTest do
  @moduledoc """
  The offered spaces are held for a few minutes, so a screen is not a request
  per render — and a failed listing is not remembered as though it were an
  answer.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.SpaceDirectory

  # The cache runs the fetching function in its own process, so a test that
  # counts calls cannot send itself a message; it counts instead.
  setup do
    calls = :counters.new(1, [:atomics])
    :persistent_term.put({__MODULE__, :calls}, calls)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :calls}) end)
    {:ok, calls: calls}
  end

  @doc false
  def calls, do: :persistent_term.get({__MODULE__, :calls})

  defmodule CountingSource do
    def spaces(_opts) do
      :counters.add(ConfluencePhxMirror.SpaceDirectoryTest.calls(), 1, 1)
      {:ok, [%{key: "ENG", name: "Engineering", type: "global"}]}
    end
  end

  defmodule BrokenSource do
    def spaces(_opts) do
      :counters.add(ConfluencePhxMirror.SpaceDirectoryTest.calls(), 1, 1)
      {:error, :nope}
    end
  end

  defmodule ListingSource do
    def spaces(_opts) do
      :counters.add(ConfluencePhxMirror.SpaceDirectoryTest.calls(), 1, 1)

      {:ok,
       [
         %{key: "LOAD01", name: "Load testing", type: "global"},
         %{key: "LOAD02", name: "Load archives", type: "global"},
         %{key: "ENG", name: "Engineering Handbook", type: "global"},
         %{key: "~jane", name: "Jane Doe", type: "personal"}
       ]}
    end
  end

  describe "suggesting what a key could be" do
    test "matches the key or the name, in any case" do
      assert {:ok, suggested} = SpaceDirectory.suggest("load", source: ListingSource)
      assert Enum.map(suggested, & &1.key) == ["LOAD02", "LOAD01"]

      assert {:ok, [%{key: "ENG"}]} = SpaceDirectory.suggest("handbook", source: ListingSource)
    end

    test "never offers a personal space" do
      assert {:ok, suggested} = SpaceDirectory.suggest("jane", source: ListingSource)
      assert suggested == []
    end

    test "leaves out the keys the field already names" do
      assert {:ok, suggested} =
               SpaceDirectory.suggest("load", excluding: ["LOAD01"], source: ListingSource)

      assert Enum.map(suggested, & &1.key) == ["LOAD02"]
    end

    test "an empty term offers the listing from the top, up to the limit" do
      assert {:ok, suggested} = SpaceDirectory.suggest("", limit: 2, source: ListingSource)
      assert length(suggested) == 2
    end

    test "a site that does not answer offers nothing to pick" do
      assert {:error, :nope} = SpaceDirectory.suggest("load", source: BrokenSource)
    end
  end

  test "holds the listing, and asks the source again only when told to", %{calls: calls} do
    assert {:ok, [%{key: "ENG"}]} = SpaceDirectory.available(source: CountingSource)
    assert :counters.get(calls, 1) == 1

    assert {:ok, [%{key: "ENG"}]} = SpaceDirectory.available(source: CountingSource)
    assert :counters.get(calls, 1) == 1

    assert {:ok, [%{key: "ENG"}]} = SpaceDirectory.refresh(source: CountingSource)
    assert :counters.get(calls, 1) == 2
  end

  test "does not remember a failure", %{calls: calls} do
    assert {:error, :nope} = SpaceDirectory.available(source: BrokenSource)
    assert :counters.get(calls, 1) == 1

    assert {:error, :nope} = SpaceDirectory.available(source: BrokenSource)
    assert :counters.get(calls, 1) == 2
  end
end
