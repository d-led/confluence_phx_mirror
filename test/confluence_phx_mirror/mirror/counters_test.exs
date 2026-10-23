defmodule ConfluencePhxMirror.Mirror.CountersTest do
  @moduledoc """
  The counters the home page prints: computed once per version of the content,
  and recomputed the moment the content moves.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.QueryCounter

  test "a quiet mirror answers from memory after the first question" do
    space = space_fixture()
    page_fixture(space)

    assert QueryCounter.count(fn -> Mirror.stats() end) == 2
    assert QueryCounter.count(fn -> Mirror.stats() end) == 1
  end

  test "a page arriving moves the totals" do
    space = space_fixture()
    page_fixture(space)

    assert %{pages: 1} = Mirror.stats()

    page_fixture(space)

    assert %{pages: 2} = Mirror.stats()
  end

  test "each space's count follows its own pages" do
    space = space_fixture(%{key: "CNT", name: "Counted"})
    page_fixture(space)

    assert [{^space, 1}] = Mirror.spaces_with_counts()

    page_fixture(space)

    assert [{^space, 2}] = Mirror.spaces_with_counts()
  end
end
