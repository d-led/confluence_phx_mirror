defmodule ConfluencePhxMirror.ResourcesReadTest do
  @moduledoc """
  Reading the mount is reading a cache.

  The walk that fills it runs in `Resources`' own process on its own schedule, so
  a reader must get the last measurement rather than wait for the next one. It
  waited once and it cost three runs: the walk of a big store on a loaded machine
  outlived the five seconds a `GenServer.call` allows by default, and a metrics
  publish inside `Sync.run/2` died of it — reported as a `Resources` mount
  timeout in a fixture's `demo_snapshot!`, which looks nothing like its cause.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Resources

  test "the mount answers from the last measurement while the measurer is busy" do
    measured = Resources.mount()

    on_exit(fn -> :sys.resume(Resources) end)
    :sys.suspend(Resources)

    assert Resources.mount() == measured
  end
end
