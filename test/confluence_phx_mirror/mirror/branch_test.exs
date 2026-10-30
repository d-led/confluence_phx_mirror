defmodule ConfluencePhxMirror.Mirror.BranchTest do
  @moduledoc """
  What the sidebar shows on a page.

  A page view draws the trail to the page it is showing — each level with its
  siblings, and the page's children — instead of the whole space. These cases
  pin that shape, the window that keeps a wide level bounded, and the rule that
  a page the reader may not open never appears.
  """

  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror

  setup do
    # A page id is Confluence's, so a fixed small number is a row another test
    # may be inserting at the same moment — and then two transactions wait on one
    # unique index entry and the suite deadlocks. Each test gets its own block.
    base = System.unique_integer([:positive]) * 1_000

    %{space: space_fixture(%{key: "BRN", name: "Branching"}), id: fn number -> base + number end}
  end

  test "the sidebar is the trail to the page, not the whole space", %{space: space, id: id} do
    root = page_fixture(space, %{confluence_id: id.(1), title: "Root"})
    middle = page_fixture(space, %{confluence_id: id.(2), title: "Middle", parent_id: root.id})

    leaf =
      page_fixture(space, %{
        confluence_id: id.(3),
        title: "Leaf",
        parent_id: middle.id,
        ancestors: [id.(1), id.(2)]
      })

    _unrelated = page_fixture(space, %{confluence_id: id.(4), title: "Unrelated"})

    %{nodes: nodes, truncated?: truncated?} = Authorization.branch(anonymous(), space.id, leaf)

    refute truncated?

    assert [
             %{
               page: %{title: "Root"},
               children: [
                 %{page: %{title: "Middle"}, children: [%{page: %{title: "Leaf"}, children: []}]}
               ]
             },
             %{page: %{title: "Unrelated"}, children: []}
           ] = nodes
  end

  test "a level wider than the window is cut around the reader, and says so", %{
    space: space,
    id: id
  } do
    root = page_fixture(space, %{confluence_id: id.(1), title: "Root"})

    page =
      page_fixture(space, %{
        confluence_id: id.(500),
        title: "Page 500",
        parent_id: root.id,
        ancestors: [id.(1)]
      })

    for index <- 1..100 do
      page_fixture(space, %{
        confluence_id: id.(1_000 + index),
        title: "Sibling #{index}",
        parent_id: root.id
      })
    end

    %{nodes: [%{children: children}], truncated?: truncated?} =
      Authorization.branch(anonymous(), space.id, page)

    assert truncated?
    assert length(children) == 15
    assert Enum.any?(children, &(&1.page.title == "Page 500"))
  end

  test "a page the reader may not open is left out", %{space: space, id: id} do
    root = page_fixture(space, %{confluence_id: id.(1), title: "Root"})

    open =
      page_fixture(space, %{
        confluence_id: id.(2),
        title: "Open",
        parent_id: root.id,
        ancestors: [id.(1)]
      })

    secret = page_fixture(space, %{confluence_id: id.(3), title: "Secret", parent_id: root.id})

    {:ok, _} =
      Mirror.replace_page_restrictions(secret, [
        %{subject_type: "group", subject_key: "the-inner-circle"}
      ])

    %{nodes: [%{children: children}]} = Authorization.branch(anonymous(), space.id, open)

    assert Enum.map(children, & &1.page.title) == ["Open"]
  end

  test "a space without a page shows its roots", %{space: space, id: id} do
    root = page_fixture(space, %{confluence_id: id.(1), title: "Root"})

    page_fixture(space, %{
      confluence_id: id.(2),
      title: "Child",
      parent_id: root.id,
      ancestors: [id.(1)]
    })

    %{nodes: nodes, truncated?: false} = Authorization.branch(anonymous(), space.id)

    assert Enum.map(nodes, & &1.page.title) == ["Root"]
    assert Enum.map(nodes, & &1.children) == [[]]
  end

  defp anonymous, do: Scope.for_user(nil)
end
