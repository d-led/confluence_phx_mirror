defmodule ConfluencePhxMirror.Sync.SweepWorkerTest do
  @moduledoc """
  A full re-read is a queue of spaces, not one enormous run: what the sweep
  hands to the queue is the contract, and each space job then does the work.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Confluence.{FailingSource, Source}
  alias ConfluencePhxMirror.Sync.{SpaceWorker, SweepWorker}

  test "queues one space job per space the site lists" do
    assert :ok = perform_job(SweepWorker, %{"trigger" => "an administrator"})

    queued = all_enqueued(worker: SpaceWorker)
    {:ok, spaces} = Source.source().spaces([])

    assert queued |> Enum.map(& &1.args["space_key"]) |> Enum.sort() ==
             spaces |> Enum.map(& &1.key) |> Enum.sort()

    assert Enum.all?(queued, &(&1.args["trigger"] == "an administrator"))
  end

  test "names itself in the queue when nobody said why" do
    assert :ok = perform_job(SweepWorker, %{})

    assert all_enqueued(worker: SpaceWorker) |> Enum.all?(&(&1.args["trigger"] == "the sweep"))
  end

  test "a site that cannot be listed queues nothing and fails" do
    configure_source(FailingSource)

    error = assert_raise RuntimeError, fn -> perform_job(SweepWorker, %{}) end

    assert error.message =~ ":unreachable"
    assert all_enqueued(worker: SpaceWorker) == []
  end

  defp configure_source(source) do
    previous = Application.get_env(:confluence_phx_mirror, :source)
    Application.put_env(:confluence_phx_mirror, :source, source)

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :source, previous) end)
  end
end
