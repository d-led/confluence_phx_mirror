defmodule ConfluencePhxMirror.SyncGateTest do
  # Not `DataCase`: these tests hold the gate from a *second* process on
  # purpose, and only a shared owner lets a spawned task query the database.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{Gate, SyncRun}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  describe "one run at a time" do
    test "the second caller is refused while the first holds the lock" do
      test_process = self()

      holder =
        Task.async(fn ->
          Gate.exclusive(fn _owner ->
            send(test_process, :locked)

            receive do
              :release -> :done
            end
          end)
        end)

      assert_receive :locked
      assert Gate.held?()
      assert {:error, :already_running} = Gate.exclusive(fn _owner -> :never_runs end)

      send(holder.pid, :release)
      assert {:ok, :done} = Task.await(holder)
      refute Gate.held?()
    end

    test "a sync that finds the lock taken starts nothing" do
      test_process = self()

      holder =
        Task.async(fn ->
          Gate.exclusive(fn _owner ->
            send(test_process, :locked)

            receive do
              :release -> :done
            end
          end)
        end)

      assert_receive :locked
      assert {:error, :already_running} = Sync.run(:snapshot)
      assert Repo.aggregate(SyncRun, :count) == 0

      send(holder.pid, :release)
      Task.await(holder)
    end
  end

  describe "abandoned runs" do
    test "a running row nobody holds the lock for is reported abandoned" do
      run = insert_run("running")

      assert Sync.abandon_abandoned_runs() == 1

      run = Repo.get!(SyncRun, run.id)
      assert run.status == "failed"
      assert run.error =~ "stopped before it finished"
    end

    test "a run that is really running is left alone" do
      run = insert_run("running")

      Gate.exclusive(fn _owner ->
        assert Sync.abandon_abandoned_runs() == 0
      end)

      assert Repo.get!(SyncRun, run.id).status == "running"
    end

    test "finished runs are none of its business" do
      run = insert_run("succeeded")

      assert Sync.abandon_abandoned_runs() == 0
      assert Repo.get!(SyncRun, run.id).status == "succeeded"
    end
  end

  describe "asking a run to stop" do
    test "a running run takes the request" do
      run = insert_run("running")

      assert {:ok, %SyncRun{cancel_requested_at: %DateTime{}}} =
               Sync.cancel(run.id, {:system, "test"})

      assert Repo.get!(SyncRun, run.id).status == "running"
    end

    test "a run that already finished cannot be cancelled" do
      run = insert_run("succeeded")

      assert {:error, :not_running} = Sync.cancel(run.id, {:system, "test"})
    end
  end

  defp insert_run(status) do
    %SyncRun{}
    |> SyncRun.changeset(%{
      source: "test",
      mode: "snapshot",
      status: status,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      finished_at: if(status == "running", do: nil, else: DateTime.utc_now())
    })
    |> Repo.insert!()
  end
end
