defmodule ConfluencePhxMirror.Sync.SpaceScopeTest do
  @moduledoc """
  Which spaces a run may import: the deployment's own keys, plus the ones an
  administrator added — or everything, when neither names anything.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync.SpaceScope

  @actor {:system, "test"}

  setup do
    previous = Application.get_env(:confluence_phx_mirror, HttpSource)
    Settings.reload()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:confluence_phx_mirror, HttpSource, previous),
        else: Application.delete_env(:confluence_phx_mirror, HttpSource)

      Settings.reload()
    end)

    :ok
  end

  test "nobody naming anything means every space" do
    assert SpaceScope.wanted() == :all
    assert SpaceScope.import?("ENG")
    assert SpaceScope.import?("ANY-OTHER")
  end

  test "the deployment's own keys are the floor" do
    configured_spaces(["ENG", "OPS"])

    assert SpaceScope.wanted() == ["ENG", "OPS"]
    assert SpaceScope.import?("ENG")
    refute SpaceScope.import?("PROD")
  end

  test "the runtime list widens the deployment's and cannot narrow it" do
    configured_spaces(["ENG"])
    assert {:ok, _applied} = Settings.update(%{"sync.spaces" => "prod, OPS"}, @actor)

    assert SpaceScope.wanted() == ["ENG", "PROD", "OPS"]
    assert SpaceScope.import?("PROD")
    assert SpaceScope.import?("ENG")
  end

  test "on its own, the runtime list is the whole whitelist" do
    assert {:ok, _applied} = Settings.update(%{"sync.spaces" => "ENG,PROD"}, @actor)

    assert SpaceScope.wanted() == ["ENG", "PROD"]
    refute SpaceScope.import?("OPS")
  end

  test "naming one on a mirror that held everything makes it the whitelist" do
    configured_spaces(:all)
    assert {:ok, _applied} = Settings.update(%{"sync.spaces" => "ENG"}, @actor)

    assert SpaceScope.wanted() == ["ENG"]
    refute SpaceScope.import?("OPS")
  end

  defp configured_spaces(spaces) do
    Application.put_env(:confluence_phx_mirror, HttpSource, spaces: spaces)
  end
end
