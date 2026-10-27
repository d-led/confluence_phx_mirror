defmodule ConfluencePhxMirror.SpaceDirectoryTest do
  @moduledoc """
  The offered spaces are held for a few minutes, so a screen is not a request
  per render — and a failed listing is not remembered as though it were an
  answer.
  """

  use ExUnit.Case, async: false

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
