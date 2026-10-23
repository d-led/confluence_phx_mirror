defmodule ConfluencePhxMirror.Confluence.SyntheticSourceTest do
  @moduledoc """
  The generated snapshot behaves like a site: it lists spaces, pages with a
  tree, and the sync turns it into a mirror a reader could browse.

  These are also the tests that keep the scale fixture honest — the fixture
  writes rows directly, and this is where the rows a sync writes are held to it.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Confluence.{SyntheticContent, SyntheticSource}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Synthetic

  @config [spaces: 2, pages_per_space: 6, branching: 2]

  setup do
    Application.put_env(:confluence_phx_mirror, SyntheticSource, @config)
    on_exit(fn -> Application.delete_env(:confluence_phx_mirror, SyntheticSource) end)
    :ok
  end

  test "a space lists its pages with a tree of ancestors" do
    {:ok, spaces} = SyntheticSource.spaces([])
    {:ok, pages} = SyntheticSource.pages("S0001", [])

    assert Enum.map(spaces, & &1.key) == ["S0001", "S0002"]

    titles = Enum.map(pages, & &1.title)
    assert length(titles) == 6
    assert Enum.uniq(titles) == titles

    # Page 1 is the root; pages 2 and 3 are its children; pages 4 and 5 are
    # children of page 2.
    assert Enum.at(pages, 0).parent_id == nil
    assert Enum.at(pages, 1).ancestors == [SyntheticContent.page_id(1, 1)]
    assert Enum.at(pages, 2).ancestors == [SyntheticContent.page_id(1, 1)]

    assert Enum.at(pages, 3).ancestors == [
             SyntheticContent.page_id(1, 1),
             SyntheticContent.page_id(1, 2)
           ]
  end

  test "an id names a page, and anything else is not found" do
    assert {:ok, page} = SyntheticSource.page(SyntheticContent.page_id(2, 3), [])
    assert page.space_key == "S0002"
    assert page.title == Enum.at(elem(SyntheticSource.pages("S0002", []), 1), 2).title

    assert {:error, :not_found} = SyntheticSource.page(SyntheticContent.page_id(9, 1), [])
    assert {:error, :not_found} = SyntheticSource.page(SyntheticContent.page_id(1, 99), [])
  end

  test "a snapshot of the generated site is a browsable mirror" do
    assert {:ok, run} = Sync.run(:snapshot, source: SyntheticSource)

    assert run.stats["spaces"] == 2
    assert run.stats["pages"] == 12

    home = Mirror.get_page!(SyntheticContent.page_id(1, 1))
    assert home.space.key == "S0001"
    assert home.parent_id == nil

    child = Mirror.get_page!(SyntheticContent.page_id(1, 3))
    assert child.parent_id == home.id
    assert child.ancestors == [home.confluence_id]

    # The sidebar of the home page: the space's roots, with this page expanded
    # and its children under it.
    assert [%{page: %{title: home_title}, children: children}] =
             Authorization.branch(Scope.for_user(nil), home.space_id, home).nodes

    assert home_title == home.title

    assert Enum.map(children, & &1.page.title) == [
             "Page 0002 — Onboarding",
             "Page 0003 — Runbook"
           ]
  end

  test "the scale fixture writes the rows a sync writes" do
    {:ok, _run} = Sync.run(:snapshot, source: SyntheticSource)
    synced = Mirror.get_page!(SyntheticContent.page_id(1, 3))
    synced_tree = page_shape(synced)

    Synthetic.seed!(@config)
    seeded = Mirror.get_page!(SyntheticContent.page_id(1, 3))

    assert page_shape(seeded) == synced_tree
  end

  # Local ids differ between the two writers; what must not differ is what the
  # row says about the page and where it sits in its space.
  defp page_shape(page) do
    %{
      title: page.title,
      slug: page.slug,
      type: page.type,
      status: page.status,
      ancestors: page.ancestors,
      labels: page.labels,
      version: page.version_number,
      author: page.author_name,
      space_key: page.space.key,
      parent_title:
        page.parent_id && Mirror.find_page_by_local_id(page.parent_id) |> parent_title()
    }
  end

  defp parent_title({:ok, parent}), do: parent.title
  defp parent_title(_none), do: nil
end
