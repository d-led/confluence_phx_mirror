defmodule ConfluencePhxMirror.Ecto.IdStringTest do
  @moduledoc """
  An attachment id is text, whichever spelling the store hands back.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Ecto.IdString

  test "a numeric id comes back as the text the site would have given" do
    # SQLite stores `"9003"` in a numeric-affinity column as 9003 and reads the
    # number back; the column is an identifier, and so is the value.
    assert IdString.load(9003) == {:ok, "9003"}
    assert IdString.cast(9003) == {:ok, "9003"}
    assert IdString.dump(9003) == {:ok, "9003"}
  end

  test "an id the site spells with letters is left alone" do
    assert IdString.load("att164058") == {:ok, "att164058"}
    assert IdString.cast("att164058") == {:ok, "att164058"}
    assert IdString.dump("att164058") == {:ok, "att164058"}
  end

  test "nothing is nothing" do
    assert IdString.load(nil) == {:ok, nil}
    assert IdString.cast(nil) == {:ok, nil}
  end

  test "anything else is refused rather than guessed at" do
    assert IdString.cast(:atom) == :error
    assert IdString.load(%{}) == :error
  end
end
