defmodule ConfluencePhxMirror.SyncGateTest do
  # Not `DataCase`: these tests hold the gate from a *second* process on
  # purpose, and only a shared owner lets a spawned task query the database.
  use ExUnit.Case, async: false

  import Ecto.Query

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync

  alias ConfluencePhxMirror.Sync.{
    Gate,
    ReconcileWorker,
    SnapshotWorker,
    SyncRun,
    TrashAbsentWorker
  }

  alias ConfluencePhxMirror.TestConfig

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
      runs_before = Repo.aggregate(SyncRun, :count)

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
      assert Repo.aggregate(SyncRun, :count) == runs_before

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
      # How long it had been silent, so a deploy and a dead run read differently.
      assert run.error =~ ~r/\(\d+s without progress\)/
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

    test "a job left executing by a process that is gone is cancelled" do
      # This is the shape production got into: the run row was already closed
      # (a deploy killed it), but the job stayed `executing` — and an executing
      # job keeps its uniqueness, so the next scheduled pull was turned away.
      job = insert_executing_job(SnapshotWorker, minutes_ago: 10)

      assert Sync.abandon_abandoned_runs() == 0

      assert Repo.get!(Oban.Job, job.id).state == "cancelled"

      # Which is the point: the queue takes the next pull again.
      assert {:ok, _next} =
               %{id: nil, mode: "incremental"} |> SnapshotWorker.new() |> Oban.insert()
    end

    test "a job that runs beside the lock is not judged by it" do
      # A trash pass takes no lock, because it is not a sync: it copies nothing
      # and asks one question. Reading the free lock as "nobody is doing that"
      # cancelled a healthy pass a minute in, every time.
      job = insert_executing_job(TrashAbsentWorker, minutes_ago: 10)

      assert Sync.abandon_abandoned_runs() == 0

      assert Repo.get!(Oban.Job, job.id).state == "executing"
    end

    test "a verify pass left executing with the lock free is cancelled" do
      # The incident this exists for: a deploy killed a pass, the job stayed
      # `executing`, and its uniqueness turned every later schedule away until
      # Oban's lifeline noticed — six hours. A pass takes the lock now, so a free
      # lock says its process is gone.
      job = insert_executing_job(ReconcileWorker, minutes_ago: 10)

      assert Sync.abandon_abandoned_runs() == 0

      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end

    test "a job that has only just started is left alone" do
      # It has not taken the lock yet; silence is not death.
      job = insert_executing_job(SnapshotWorker, minutes_ago: 0)

      Sync.abandon_abandoned_runs()

      assert Repo.get!(Oban.Job, job.id).state == "executing"
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

  # The lease is one and a half minutes in production, which no test can wait
  # out. Shortened here, the same property holds: work that takes longer than a
  # lease is still work, and the gate has to say so.
  #
  # `expires_at` is whole seconds, so a one-second lease has no resolution left:
  # `held?` at the moment a lease is written and at the last instant of it both
  # compare seconds that can be equal. That is why the test asks whether the
  # lease *moved* rather than whether it is currently in the future, and why the
  # abandonment guard is checked while the claim is fresh.
  describe "a run slower than its lease" do
    setup do
      TestConfig.put(
        :sync,
        Keyword.put(
          Application.get_env(:confluence_phx_mirror, :sync) || [],
          :gate_lease_seconds,
          1
        )
      )
    end

    test "keeps pushing its lease forward while it works" do
      Gate.exclusive(fn owner ->
        first = expires_at(owner)
        Process.sleep(1_300)

        assert NaiveDateTime.compare(expires_at(owner), first) == :gt
      end)
    end

    test "is never mistaken for an abandoned one" do
      run = insert_run("running")

      Gate.exclusive(fn _owner ->
        assert Sync.abandon_abandoned_runs() == 0
      end)

      assert Repo.get!(SyncRun, run.id).status == "running"
    end
  end

  defp expires_at(owner) do
    Repo.one(from g in "sync_gate", where: g.owner == ^owner, select: g.expires_at)
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

  defp insert_executing_job(worker, minutes_ago: minutes) do
    {:ok, job} = worker.new(%{}) |> Oban.insert()

    attempted_at = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    job
    |> Ecto.Changeset.change(state: "executing", attempted_at: attempted_at)
    |> Repo.update!()
  end
end
