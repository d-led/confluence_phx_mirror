defmodule ConfluencePhxMirror.Sync.StopTest do
  @moduledoc """
  Stopping a run is a process exit, and the write boundary is what makes that
  safe: the version change that clears `details_synced_at` and the details
  themselves are transactions, so a stopped run leaves the page in the backlog
  rather than half written.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Comment, Page}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{Runs, SyncRun}

  # The demo snapshot, after a comment with a screenshot was left on page 1002
  # — and with the read of that page's comments blocking, so a stop can be
  # asked for while the page's new version is stored and its details are about
  # to be written.
  defmodule AskingSource do
    @behaviour ConfluencePhxMirror.Confluence.Source

    alias ConfluencePhxMirror.Confluence.CommentedSource

    @impl true
    defdelegate name(), to: CommentedSource
    @impl true
    defdelegate kind(), to: CommentedSource
    @impl true
    defdelegate spaces(opts), to: CommentedSource
    @impl true
    defdelegate pages(space_key, opts), to: CommentedSource
    @impl true
    defdelegate page(confluence_id, opts), to: CommentedSource
    @impl true
    defdelegate restrictions(confluence_id, opts), to: CommentedSource
    @impl true
    defdelegate space_permissions(space_key, opts), to: CommentedSource
    @impl true
    defdelegate group_members(group_name, opts), to: CommentedSource
    @impl true
    defdelegate user_status(account_id, opts), to: CommentedSource
    @impl true
    defdelegate attachments(confluence_id, opts), to: CommentedSource
    @impl true
    defdelegate changed_since(since, opts), to: CommentedSource
    @impl true
    defdelegate touched_since(since, opts), to: CommentedSource
    @impl true
    defdelegate attachment_data(attachment, opts), to: CommentedSource

    @impl true
    def comments(confluence_id, opts) when confluence_id in [1002, "1002"] do
      send(:persistent_term.get({__MODULE__, :test_process}), {:in_comments, self()})

      receive do
        :go -> CommentedSource.comments(confluence_id, opts)
      end
    end

    def comments(confluence_id, opts), do: CommentedSource.comments(confluence_id, opts)
  end

  setup do
    demo_snapshot!()
    :ok
  end

  test "cancelling exits the process doing the run on this node" do
    run = start_running_run()

    parent = self()

    pid =
      spawn(fn ->
        Runs.register(run.id)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    ref = Process.monitor(pid)

    assert {:ok, cancelled} = Sync.cancel(run.id, {:system, "test"})
    assert cancelled.cancel_requested_at

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert Repo.get!(SyncRun, run.id).cancel_requested_at
  end

  test "a run on another node or OS process is asked, not exited" do
    run = start_running_run()

    assert {:ok, _} = Sync.cancel(run.id, {:system, "test"})
    assert Repo.get!(SyncRun, run.id).cancel_requested_at
  end

  test "a stop that lands while a page's details are being written leaves the page in the backlog" do
    :persistent_term.put({AskingSource, :test_process}, self())
    on_exit(fn -> :persistent_term.erase({AskingSource, :test_process}) end)

    run_task = Task.async(fn -> Sync.run(:page, confluence_id: 1002, source: AskingSource) end)

    assert_receive {:in_comments, run_process}, 15_000
    assert [run_id] = Runs.running()

    # What a cancel on another node does: the row is all it can touch.
    run = Repo.get!(SyncRun, run_id)

    {:ok, _asked} =
      run
      |> SyncRun.changeset(%{cancel_requested_at: DateTime.utc_now()})
      |> Repo.update()

    send(run_process, :go)

    assert {:ok, cancelled} = Task.await(run_task, 15_000)
    assert cancelled.id == run_id
    assert cancelled.status == "cancelled"

    # The page's new version is stored and marked stale; the details that were
    # about to be written — the comment, the mark — rolled back with it.
    page = Repo.get_by!(Page, confluence_id: 1002)
    assert page.details_synced_at == nil
    assert Repo.get_by(Comment, confluence_id: 7001) == nil

    # And the page is a backlog item, so the next run reads its details instead
    # of trusting the ones that never arrived.
    assert 1002 in Mirror.pages_awaiting_details(10)
  end

  defp start_running_run do
    {:ok, run} =
      %SyncRun{}
      |> SyncRun.changeset(%{
        source: "confluence-demo",
        mode: "snapshot",
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    run
  end
end
