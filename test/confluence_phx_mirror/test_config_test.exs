defmodule ConfluencePhxMirror.TestConfigTest do
  @moduledoc """
  The one place a test changes the deployment: it has to put it back, whether the
  expression it wrapped returned or raised, and whether the key was there to
  begin with.
  """
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.TestConfig

  @seeded :admins

  test "a value holds inside the expression and is the deployment's again after it" do
    configured = Application.get_env(:confluence_phx_mirror, @seeded)

    TestConfig.with([{@seeded, ["someone@example.com"]}], fn ->
      assert Application.get_env(:confluence_phx_mirror, @seeded) == ["someone@example.com"]
    end)

    assert Application.get_env(:confluence_phx_mirror, @seeded) == configured
  end

  test "a raise inside the expression still puts it back" do
    configured = Application.get_env(:confluence_phx_mirror, @seeded)

    assert_raise RuntimeError, fn ->
      TestConfig.with([{@seeded, ["someone@example.com"]}], fn -> raise "the test broke" end)
    end

    assert Application.get_env(:confluence_phx_mirror, @seeded) == configured
  end

  test "a key the deployment does not set is removed rather than set to nil" do
    TestConfig.with([{:a_key_no_config_mentions, :set}], fn ->
      assert Application.get_env(:confluence_phx_mirror, :a_key_no_config_mentions) == :set
    end)

    # `:error` is what `fetch_env/2` answers for a key that is not there; `nil`
    # would be a key the deployment does set, to nothing.
    assert Application.fetch_env(:confluence_phx_mirror, :a_key_no_config_mentions) == :error
  end

  test "put makes the value the deployment's answer right away" do
    TestConfig.put(@seeded, ["window@example.com"])

    assert Application.get_env(:confluence_phx_mirror, @seeded) == ["window@example.com"]
  end
end
