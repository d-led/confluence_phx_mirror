defmodule ConfluencePhxMirror.Schema.JSONListTest do
  @moduledoc """
  The list a SQLite build stores as JSON text.

  Nothing calls this module by name — Ecto reaches it through the type callbacks,
  and which module a build uses is chosen at compile time — so the contract is
  the only thing that can be pinned: a list round-trips, and a stored value that
  is not one reads as no list rather than stopping an export.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Schema.JSONList

  test "a list survives the round trip it was stored for" do
    assert {:ok, stored} = JSONList.dump(["runbook", "platform"])
    assert JSONList.load(IO.iodata_to_binary(stored)) == {:ok, ["runbook", "platform"]}
  end

  test "no list is stored and read as the empty one" do
    assert JSONList.dump(nil) == {:ok, "[]"}
    assert JSONList.load(nil) == {:ok, []}
  end

  # "Reading is forgiving on purpose": a value that is not a list becomes an
  # empty one, which is also what "no labels" means — never a crash mid-export.
  test "a stored value that is not a list reads as no list" do
    assert JSONList.load(~s({"a": 1})) == {:ok, []}
    assert JSONList.load("not json at all") == {:ok, []}
  end

  test "only a list is stored, and only a list is cast" do
    assert JSONList.dump(%{a: 1}) == :error
    assert JSONList.cast(["runbook"]) == {:ok, ["runbook"]}
    assert JSONList.cast("runbook") == :error
  end

  test "the column is text, whichever database holds it" do
    assert JSONList.type() == :string
  end
end
