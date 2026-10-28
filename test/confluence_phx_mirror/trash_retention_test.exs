defmodule ConfluencePhxMirror.TrashRetentionTest do
  @moduledoc """
  Trashing what the site stopped listing, and deleting it later.

  Both halves are about what an operator can undo: a page moves to the trash and
  stops being served, and a retention policy removes what has been sitting there
  long enough — never anything younger, and never anything still live.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.{Mirror, Trash}

  @actor {:system, "the retention test"}

  setup do
    space = space_fixture(%{key: "ENG", name: "Engineering"})
    page = page_fixture(space, %{confluence_id: 1002, title: "Gone"})
    %{space: space, page: page}
  end

  test "trashing a reviewed page stops it being served, and says why", %{
    space: space,
    page: page
  } do
    assert {:ok, trashed} = Trash.trash_page(@actor, page, space)

    assert trashed.deleted_reason == "vanished"
    assert Mirror.find_page(1002) == {:error, :not_found}
    assert [{^trashed, ^space}] = Trash.pages()
    assert audit_actions() == ["page.trashed"]
  end

  test "retention purges what is old enough and keeps what is not", %{
    space: space,
    page: page
  } do
    {:ok, old} = Trash.trash_page(@actor, page, space)
    recent = page_fixture(space, %{confluence_id: 1003, title: "Recent"})
    {:ok, recent} = Trash.trash_page(@actor, recent, space)

    age!(old, 40)
    age!(recent, 2)

    assert %{spaces: [], pages: due} = Trash.due(30)
    assert Enum.map(due, fn {page, _space} -> page.title end) == ["Gone"]

    assert %{pages: 1} = Trash.purge_due(@actor, 30)

    assert Mirror.find_page(1002) == {:error, :not_found}
    assert [{kept, ^space}] = Trash.pages()
    assert kept.title == "Recent"
  end

  test "a live page is never purged, however old its absence", %{space: space} do
    page = page_fixture(space, %{confluence_id: 1004, title: "Still published"})

    assert %{pages: [], spaces: []} = Trash.due(0)
    assert %{pages: 0} = Trash.purge_due(@actor, 0)

    assert {:ok, _} = Mirror.find_page(1004)
    assert page.id
  end

  test "retention purges a trashed space with its pages", %{space: space, page: page} do
    {:ok, _live} = Mirror.find_page(page.confluence_id)
    Mirror.trash_space(space)
    age!(space, 40)

    assert %{spaces: [{trashed_space, 1}]} = Trash.due(30)
    assert trashed_space.key == "ENG"

    assert %{spaces: 1, pages: 0} = Trash.purge_due(@actor, 30)

    assert Mirror.get_space_by_key("ENG") == nil
    assert Mirror.count_pages() == 0
  end

  describe "everything the check found missing" do
    test "leaves in one go, whatever space it is in, and only what was marked", %{
      space: space,
      page: page
    } do
      other = space_fixture(%{key: "OPS", name: "Operations"})
      page_fixture(other, %{confluence_id: 2002, title: "Gone too"})
      kept = page_fixture(other, %{confluence_id: 2003, title: "Still there"})

      # What a check does: name the ids the site has, and mark the rest.
      Mirror.mark_absent(space, [])
      Mirror.mark_absent(other, [2003])

      assert Trash.trash_all_absent(@actor) == 2

      assert Mirror.find_page(1002) == {:error, :not_found}
      assert Mirror.find_page(2002) == {:error, :not_found}
      assert {:ok, _live} = Mirror.find_page(2003), "a page the site names stays"

      assert Mirror.count_absent() == 0

      assert Enum.sort(Enum.map(Trash.pages(), fn {p, _space} -> p.title end)) == [
               "Gone",
               "Gone too"
             ]

      assert page.id
      assert kept.id
    end

    test "says once what it moved, and says nothing when there was nothing", %{space: space} do
      Mirror.mark_absent(space, [])

      assert Trash.trash_all_absent(@actor) == 1

      assert [entry] = Repo.all(from(e in Event, where: e.action == "pages.deleted"))
      assert entry.metadata["count"] == 1

      assert Trash.trash_all_absent(@actor) == 0
      assert [_only] = Repo.all(from(e in Event, where: e.action == "pages.deleted"))
    end
  end

  # Backdating is how a test says "this has been sitting there a while"; the
  # trash reads `deleted_at` and nothing else.
  defp age!(%_{} = row, days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    row
    |> Ecto.Changeset.change(deleted_at: at)
    |> Repo.update!()
  end

  defp audit_actions do
    from(e in Event, where: e.action in ["page.trashed", "page.purged"], select: e.action)
    |> Repo.all()
    |> Enum.sort()
  end
end
