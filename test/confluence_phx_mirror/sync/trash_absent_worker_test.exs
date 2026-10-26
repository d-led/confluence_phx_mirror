defmodule ConfluencePhxMirror.Sync.TrashAbsentWorkerTest do
  @moduledoc """
  The bulk half of the upstream review: a whole space's absent pages, moved in a
  job rather than during a click.

  The decision is the operator's and it is already made when the job is enqueued,
  so what is asserted here is that the job does exactly that decision — the
  absent pages of the one space it names, nothing else — and leaves one record of
  it for the audit trail.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.{Mirror, Trash}
  alias ConfluencePhxMirror.Sync.TrashAbsentWorker

  setup do
    space = space_fixture(%{key: "ENG", name: "Engineering"})
    absent = page_fixture(space, %{confluence_id: 1002, title: "Gone"})
    published = page_fixture(space, %{confluence_id: 1003, title: "Still there"})
    # The site listed 1003 and not 1002, which is what marks 1002 absent.
    Mirror.mark_absent(space, [1003])

    other = space_fixture(%{key: "OPS", name: "Operations"})
    elsewhere = page_fixture(other, %{confluence_id: 2002, title: "Gone elsewhere"})
    Mirror.mark_absent(other, [])

    %{space: space, absent: absent, published: published, elsewhere: elsewhere}
  end

  test "trashes the absent pages of the space it was asked about, and only those", %{
    absent: absent,
    published: published,
    elsewhere: elsewhere
  } do
    assert :ok =
             perform_job(TrashAbsentWorker, %{"space_key" => "ENG", "asked_by" => "ops@x.test"})

    assert Mirror.find_page(absent.confluence_id) == {:error, :not_found}
    assert {:ok, _} = Mirror.find_page(published.confluence_id)

    assert {:ok, still_absent} = Mirror.find_page(elsewhere.confluence_id)
    assert still_absent.absent_since != nil, "another space's review is still waiting"

    assert [{trashed, %{key: "ENG"}}] = Trash.pages()
    assert trashed.deleted_reason == "vanished"
  end

  test "records the decision once for the space, naming how many pages went", %{absent: absent} do
    perform_job(TrashAbsentWorker, %{"space_key" => "ENG", "asked_by" => "ops@x.test"})

    assert [entry] = entries()
    assert entry.action == "pages.deleted"
    assert entry.entity_id == "ENG"
    assert entry.metadata["count"] == 1
    assert entry.actor_type == "system"
    assert entry.actor_label == "the upstream review, asked by ops@x.test"
    assert absent.id
  end

  test "a space that is no longer live does nothing" do
    Mirror.trash_space(Mirror.get_space_by_key("ENG"))
    # What the space trash itself moved is not this job's record.
    Enum.each(entries(), &Repo.delete!/1)

    assert :ok = perform_job(TrashAbsentWorker, %{"space_key" => "ENG"})

    assert entries() == []
  end

  test "a space with nothing absent leaves no record to explain" do
    space = space_fixture(%{key: "CLEAN", name: "Clean"})
    page_fixture(space, %{confluence_id: 3002, title: "Listed"})

    assert :ok = perform_job(TrashAbsentWorker, %{"space_key" => "CLEAN"})

    assert entries() == []
    assert Mirror.count_absent() == 2, "the two absent pages are untouched"
  end

  defp entries do
    from(e in Event, where: e.action == "pages.deleted", order_by: e.id)
    |> Repo.all()
  end
end
