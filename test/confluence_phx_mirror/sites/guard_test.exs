defmodule ConfluencePhxMirror.Sites.GuardTest do
  @moduledoc """
  Two audiences, two answers to the same disagreement.

  A server has nobody to ask and must not start half-configured, so it refuses
  and says why. A window has a person in front of it and no console to read a
  crash dump from, so it is told instead — the answer is kept where the tool's
  home page can show it, and syncing still refuses per run. Both are the
  decision `init/1` makes, which is why it can be asked directly here rather
  than through a supervised process the test application already has.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirror.Sites.Guard
  alias ConfluencePhxMirror.TestConfig

  setup do
    # The folder belongs to the demo snapshot; the deployment is then pointed at
    # a real site, which is the disagreement both tests are about.
    assert Sites.verify!() == :ok
    TestConfig.put(:source, HttpSource)
    TestConfig.put(HttpSource, base_url: "https://dled.atlassian.net/wiki")
    TestConfig.put(:site_conflict, nil)
    :ok
  end

  test "a window is told what disagrees rather than stopped" do
    assert {:ok, state} = Guard.init(on_conflict: :report)

    assert state.site == "dled_atlassian_net"
    assert %{recorded: "demo", configured: "dled_atlassian_net"} = Sites.conflict()
  end

  test "the same disagreement stops a server, saying which site the folder holds" do
    assert_raise RuntimeError, ~r/Refusing to mix two Confluence sites/, fn ->
      Guard.init([])
    end
  end
end
