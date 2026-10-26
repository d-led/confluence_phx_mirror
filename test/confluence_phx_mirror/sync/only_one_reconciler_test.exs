defmodule ConfluencePhxMirror.Sync.OnlyOneReconcilerTest do
  @moduledoc """
  One verify pass at a time, whatever asked for it.

  Two passes read the whole site twice and mark the same pages twice, and the
  second is invisible in the first's record. The risk was real rather than
  theoretical: the arguments carry the operator's address, so a unique key on the
  default fields would treat "asked by jane" and "asked by sam" as two different
  jobs and run both.

  Oban reports the avoided duplicate as `conflict?: true` on the returned job
  rather than as an error.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.{ReconcileWorker, TrashAbsentWorker}
  alias ConfluencePhxMirror.Trash.PurgeWorker

  test "a second check joins the waiting one, whoever asked" do
    assert {:ok, %{conflict?: false}} = insert_check("jane@example.com")
    assert {:ok, %{conflict?: true}} = insert_check("sam@example.com")

    assert length(all_enqueued(worker: ReconcileWorker)) == 1
  end

  test "a second check joins the running one" do
    {:ok, _job} = insert_check("jane@example.com")
    set_state(ReconcileWorker, "executing")

    assert {:ok, %{conflict?: true}} = insert_check("jane@example.com")
  end

  test "a check that has been running for hours still blocks the next one" do
    {:ok, _job} = insert_check("jane@example.com")
    set_state(ReconcileWorker, "executing", inserted_at: ~N[2020-01-01 00:00:00])

    assert {:ok, %{conflict?: true}} = insert_check("jane@example.com")
  end

  test "a check that finished leaves room for the next one" do
    {:ok, _job} = insert_check("jane@example.com")
    set_state(ReconcileWorker, "completed")

    assert {:ok, %{conflict?: false}} = insert_check("jane@example.com")
    assert length(all_enqueued(worker: ReconcileWorker)) == 1
  end

  test "one space is trashed once, two spaces at the same time" do
    space = space_fixture(%{key: "ENG"})
    page_fixture(space, %{confluence_id: 1002})
    Mirror.mark_absent(space, [])

    assert {:ok, %{conflict?: false}} = insert_trash("ENG")
    assert {:ok, %{conflict?: true}} = insert_trash("ENG", "someone-else@example.com")

    assert {:ok, %{conflict?: false}} = insert_trash("OPS")
  end

  test "one retention purge at a time, however many days were asked for" do
    assert {:ok, %{conflict?: false}} = purge(30)
    assert {:ok, %{conflict?: true}} = purge(90)
  end

  defp insert_check(asked_by) do
    ReconcileWorker.new(%{"trigger" => "the admin screen, by #{asked_by}"}) |> Oban.insert()
  end

  defp insert_trash(space_key, asked_by \\ "ops@example.com") do
    TrashAbsentWorker.new(%{"space_key" => space_key, "asked_by" => asked_by}) |> Oban.insert()
  end

  defp purge(days), do: PurgeWorker.new(%{"older_than_days" => days}) |> Oban.insert()

  # A queued job is `available`, a running one `executing`; both are inside the
  # worker's unique states, while `completed` is deliberately outside them.
  defp set_state(worker, state, extra \\ []) do
    from(j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(worker))
    |> Repo.update_all(set: [state: state] ++ extra)
  end
end
