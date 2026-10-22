defmodule ConfluencePhxMirror.Config.IdentityGuardTest do
  @moduledoc """
  The identity shortcuts belong to development and to the demo; a release that
  mirrors a real site must not honour them by accident.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Config.IdentityGuard
  alias ConfluencePhxMirror.Confluence.{DemoSource, HttpSource}

  describe "in development and test" do
    test "the shortcuts are allowed, whatever source is mirrored" do
      assert IdentityGuard.allowed?(:dev, HttpSource, false)
      assert IdentityGuard.allowed?(:test, HttpSource, false)
    end
  end

  describe "in production" do
    test "the demo source may use them, because that is what they are for" do
      assert IdentityGuard.allowed?(:prod, DemoSource, false)
    end

    test "a real site needs the acknowledgement" do
      refute IdentityGuard.allowed?(:prod, HttpSource, false)
      assert IdentityGuard.allowed?(:prod, HttpSource, true)
    end
  end

  describe "reading the switches" do
    test "only the values the deployment guide lists enable anything" do
      for value <- ["1", "true", "yes"], do: assert(IdentityGuard.enabled?(value))

      for value <- [nil, "", "0", "false", "no", "on"], do: refute(IdentityGuard.enabled?(value))
    end
  end
end
