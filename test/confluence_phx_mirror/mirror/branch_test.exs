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
    %{space: space_fixture(%{key: "BRN", name: "Branching"})}
  end

  test "the sidebar is the trail to the page, not the whole space", %{space: space} do
    root = page_fixture(space, %{confluence_id: 1, title: "Root"})
    middle = page_fixture(space, %{confluence_id: 2, title: "Middle", parent_id: root.id})

    leaf =
      page_fixture(space, %{
        confluence_id: 3,
        title: "Leaf",
        parent_id: middle.id,
        ancestors: [1, 2]
      })

    _unrelated = page_fixture(space, %{confluence_id: 4, title: "Unrelated"})

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

  test "a level wider than the window is cut around the reader, and says so", %{space: space} do
    root = page_fixture(space, %{confluence_id: 1, title: "Root"})

    page =
      page_fixture(space, %{
        confluence_id: 500,
        title: "Page 500",
        parent_id: root.id,
        ancestors: [1]
      })

    for index <- 1..100 do
      page_fixture(space, %{
        confluence_id: 1000 + index,
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

  test "a page the reader may not open is left out", %{space: space} do
    root = page_fixture(space, %{confluence_id: 1, title: "Root"})

    open =
      page_fixture(space, %{confluence_id: 2, title: "Open", parent_id: root.id, ancestors: [1]})

    secret = page_fixture(space, %{confluence_id: 3, title: "Secret", parent_id: root.id})

    {:ok, _} =
      Mirror.replace_page_restrictions(secret, [
        %{subject_type: "group", subject_key: "the-inner-circle"}
      ])

    %{nodes: [%{children: children}]} = Authorization.branch(anonymous(), space.id, open)

    assert Enum.map(children, & &1.page.title) == ["Open"]
  end

  test "a space without a page shows its roots", %{space: space} do
    root = page_fixture(space, %{confluence_id: 1, title: "Root"})
    page_fixture(space, %{confluence_id: 2, title: "Child", parent_id: root.id, ancestors: [1]})

    %{nodes: nodes, truncated?: false} = Authorization.branch(anonymous(), space.id)

    assert Enum.map(nodes, & &1.page.title) == ["Root"]
    assert Enum.map(nodes, & &1.children) == [[]]
  end

  defp anonymous, do: Scope.for_user(nil)
end
