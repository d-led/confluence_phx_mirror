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

  alias ConfluencePhxMirror.{Mirror, Trash}
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

  defp age!(%_{} = row, days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    row |> Ecto.Changeset.change(deleted_at: at) |> Repo.update!()
  end
end
