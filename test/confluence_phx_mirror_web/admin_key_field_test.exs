defmodule ConfluencePhxMirrorWeb.Admin.KeyFieldTest do
  @moduledoc """
  The runtime whitelist is one text field for a list of keys, so completing a
  suggestion has to know where the operator was typing.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirrorWeb.Admin.KeyField

  describe "completing a key" do
    test "an empty field becomes the key" do
      assert KeyField.complete("", "LOAD01") == "LOAD01"
    end

    test "a segment the key extends is replaced, not duplicated" do
      assert KeyField.complete("ENG, LO", "LOAD01") == "ENG, LOAD01"
    end

    test "a field ending in a comma takes the key after it" do
      assert KeyField.complete("ENG, ", "LOAD01") == "ENG, LOAD01"
    end

    test "a finished key stays, and the new one follows it" do
      assert KeyField.complete("ENG", "LOAD01") == "ENG, LOAD01"
    end

    test "a key already named is not named twice" do
      assert KeyField.complete("ENG, PROD", "ENG") == "ENG, PROD"
    end

    test "a half-typed key the operator picks is spelled the way the site spells it" do
      assert KeyField.complete("PROD, eng", "ENG") == "PROD, ENG"
    end
  end

  describe "what is being typed" do
    test "is the last segment of the list" do
      assert KeyField.pending("ENG, LO") == "LO"
      assert KeyField.pending("ENG") == "ENG"
    end

    test "is blank in an empty field" do
      assert KeyField.pending("") == ""
      assert KeyField.pending(nil) == ""
    end
  end

  describe "whether a list belongs under the field" do
    test "not before anything is typed" do
      refute KeyField.open?("")
      refute KeyField.open?(nil)
    end

    test "once a key is being typed" do
      assert KeyField.open?("lo")
    end

    test "after a comma, which asks for another key" do
      assert KeyField.open?("ENG, ")
    end
  end

  test "the keys are read back in the order they are named" do
    assert KeyField.keys("ENG,  PROD , ") == ["ENG", "PROD"]
    assert KeyField.keys("") == []
  end

  describe "the keys already settled on" do
    test "leave out the segment being typed" do
      assert KeyField.named("eng") == []
      assert KeyField.named("PROD, eng") == ["PROD"]
    end

    test "are all of them once a comma asks for another" do
      assert KeyField.named("ENG, ") == ["ENG"]
    end
  end
end
