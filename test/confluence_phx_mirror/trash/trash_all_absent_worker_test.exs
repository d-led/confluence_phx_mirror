defmodule ConfluencePhxMirror.Trash.TrashAllAbsentWorkerTest do
  @moduledoc """
  The one-click clear: everything the check marked, in one job.

  The check is what decides; the job only moves what is marked. So what is
  asserted here is that it moves exactly the marked pages of every space, records
  the decision once with whose it was, and leaves the rest of the mirror alone.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.{Mirror, Trash}
  alias ConfluencePhxMirror.Trash.TrashAllAbsentWorker

  setup do
    eng = space_fixture(%{key: "ENG", name: "Engineering"})
    ops = space_fixture(%{key: "OPS", name: "Operations"})

    gone = page_fixture(eng, %{confluence_id: 1002, title: "Gone"})
    also_gone = page_fixture(ops, %{confluence_id: 2002, title: "Gone elsewhere"})
    listed = page_fixture(ops, %{confluence_id: 2003, title: "Still there"})

    # What a check does: name the ids the site still has, and mark the rest.
    Mirror.mark_absent(eng, [])
    Mirror.mark_absent(ops, [2003])

    %{gone: gone, also_gone: also_gone, listed: listed}
  end

  test "moves the marked pages of every space, and only those", %{
    gone: gone,
    also_gone: also_gone,
    listed: listed
  } do
    assert :ok = perform_job(TrashAllAbsentWorker, %{"asked_by" => "ops@x.test"})

    assert Mirror.find_page(gone.confluence_id) == {:error, :not_found}
    assert Mirror.find_page(also_gone.confluence_id) == {:error, :not_found}
    assert {:ok, _live} = Mirror.find_page(listed.confluence_id)

    assert Mirror.count_absent() == 0
    assert length(Trash.pages()) == 2
  end

  test "records the decision once, naming how many pages went and who asked" do
    perform_job(TrashAllAbsentWorker, %{"asked_by" => "ops@x.test"})

    assert [entry] = Repo.all(from(e in Event, where: e.action == "pages.deleted"))
    assert entry.metadata["count"] == 2
    assert entry.actor_label == "the missing-pages review, asked by ops@x.test"
  end

  test "a mirror with nothing marked leaves no record to explain" do
    Mirror.mark_absent(Mirror.get_space_by_key("ENG"), [1002])
    Mirror.mark_absent(Mirror.get_space_by_key("OPS"), [2002, 2003])
    assert Mirror.count_absent() == 0

    assert :ok = perform_job(TrashAllAbsentWorker, %{})

    assert Repo.all(from(e in Event, where: e.action == "pages.deleted")) == []
  end
end
