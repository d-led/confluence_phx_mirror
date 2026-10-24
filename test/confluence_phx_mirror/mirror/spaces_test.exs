defmodule ConfluencePhxMirror.Mirror.SpacesTest do
  @moduledoc """
  Space keys arrive in whatever case the site felt like using; the mirror stores
  one row per key.
  """
  use ConfluencePhxMirror.DataCase, async: true

  alias ConfluencePhxMirror.Mirror

  test "a second sync of the same space updates it instead of colliding" do
    {:ok, space} = Mirror.upsert_space(%{key: "~557058abc", name: "Private", type: "personal"})
    {:ok, same} = Mirror.upsert_space(%{key: "~557058ABC", name: "Private (renamed)"})

    assert same.id == space.id
    assert same.key == "~557058ABC"
    assert same.name == "Private (renamed)"
  end

  test "spaces are stored under one canonical key" do
    {:ok, _} = Mirror.upsert_space(%{key: "mfs", name: "My first space"})

    assert Mirror.get_space_by_key("MFS").key == "MFS"
  end
end
