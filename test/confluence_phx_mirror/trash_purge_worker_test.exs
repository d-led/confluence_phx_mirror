defmodule ConfluencePhxMirror.Trash.PurgeWorkerTest do
  @moduledoc """
  The retention policy as a job: it removes what the holding period has expired
  and nothing younger.

  The screen shows the counts before the click; the job asks `Trash.purge_due/2`
  the same question, so a test of the job is a test of what an operator approved.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.{Mirror, TestConfig, Trash}
  alias ConfluencePhxMirror.Trash.PurgeWorker

  setup do
    space = space_fixture(%{key: "ENG", name: "Engineering"})
    old = page_fixture(space, %{confluence_id: 1002, title: "Long gone"})
    young = page_fixture(space, %{confluence_id: 1003, title: "Just gone"})

    {:ok, old} = Trash.trash_page({:system, "test"}, old, space)
    {:ok, _young} = Trash.trash_page({:system, "test"}, young, space)
    age!(old, 40)

    %{space: space, old: old}
  end

  test "unscheduled args use the configured holding period", %{old: old} do
    TestConfig.put(:trash, retention_days: 30)

    assert :ok = perform_job(PurgeWorker, %{})

    assert Repo.get(Mirror.Page, old.id) == nil
    assert Trash.pages() |> Enum.map(fn {page, _} -> page.title end) == ["Just gone"]
  end

  test "a holding period of zero stands the job down", %{old: old} do
    TestConfig.put(:trash, retention_days: 0)

    assert :ok = perform_job(PurgeWorker, %{})

    assert Repo.get(Mirror.Page, old.id)
    assert length(Trash.pages()) == 2
  end

  test "the args win over the setting, because the screen said so", %{old: old} do
    TestConfig.put(:trash, retention_days: 0)

    assert :ok = perform_job(PurgeWorker, %{"older_than_days" => 30})

    assert Repo.get(Mirror.Page, old.id) == nil
  end

  test "purges what the holding period has expired", %{old: old} do
    assert :ok = perform_job(PurgeWorker, %{"older_than_days" => 30, "asked_by" => "ops@x.test"})

    assert Repo.get(ConfluencePhxMirror.Mirror.Page, old.id) == nil
    assert [%{title: "Just gone"}] = Trash.pages() |> Enum.map(fn {page, _space} -> page end)
  end

  test "a holding period that has not expired deletes nothing" do
    assert :ok = perform_job(PurgeWorker, %{"older_than_days" => 90})

    assert length(Trash.pages()) == 2
  end

  test "never touches a page that is still published", %{space: space} do
    page = page_fixture(space, %{confluence_id: 1004, title: "Live"})

    assert :ok = perform_job(PurgeWorker, %{"older_than_days" => 0})

    assert {:ok, _} = Mirror.find_page(page.confluence_id)
  end

  test "a purged page takes its attachment files with it", %{old: old} do
    key = "attachments/#{old.confluence_id}/a-file.txt"
    {:ok, ^key} = Store.put(key, "the bytes a reader downloaded")
    attachment_fixture(old, %{confluence_id: "1", blob_key: key})

    assert :ok = perform_job(PurgeWorker, %{"older_than_days" => 30})

    refute Store.exists?(key), "leaving the bytes behind is what made the mirror grow"
  end

  defp age!(%_{} = row, days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    row |> Ecto.Changeset.change(deleted_at: at) |> Repo.update!()
  end
end
