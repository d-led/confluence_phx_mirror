defmodule ConfluencePhxMirror.Sync.StartupPullTest do
  @moduledoc """
  A database nobody has filled yet fills itself once — and only when, and only
  while, the deployment asks for it.

  Every case here is about a mirror, not about time: the pull reads the mirror
  it finds at boot and decides in one go.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Fixtures
  alias ConfluencePhxMirror.Sync.{SnapshotWorker, StartupPull}
  alias ConfluencePhxMirror.TestConfig

  @trigger "the first start of an empty mirror"

  @moduletag :empty_mirror

  test "an empty mirror asks for one snapshot, and says why" do
    assert {:ok, job} =
             TestConfig.with([bootstrap_sync: true], fn -> StartupPull.pull() end)

    assert job.args["trigger"] == @trigger

    assert_enqueued(
      worker: SnapshotWorker,
      args: %{"mode" => "snapshot", "trigger" => @trigger}
    )
  end

  test "a mirror that already holds content is left alone" do
    Fixtures.demo_snapshot!()

    assert TestConfig.with([bootstrap_sync: true], &StartupPull.pull/0) == :not_empty
    refute_enqueued(worker: SnapshotWorker)
  end

  test "a paused mirror is left alone" do
    outcome =
      TestConfig.with([bootstrap_sync: true, sync: paused_sync()], &StartupPull.pull/0)

    assert outcome == :paused
    refute_enqueued(worker: SnapshotWorker)
  end

  test "nothing happens unless the deployment asked for it" do
    assert StartupPull.pull() == :off
    refute_enqueued(worker: SnapshotWorker)
  end

  # The pause is one key of the `:sync` configuration, and replacing that key
  # would drop the cadences the test environment set with it.
  defp paused_sync do
    :confluence_phx_mirror
    |> Application.get_env(:sync, [])
    |> Keyword.put(:paused, true)
  end
end
