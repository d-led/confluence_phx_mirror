defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.PageTree do
  @moduledoc """
  *Page Tree*: the pages below one root, nested as deep as they go.

      <div class="mirror-macro" data-macro="pagetree" data-limit="50"></div>
      <div class="mirror-macro" data-macro="pagetree" data-root="Runbooks"></div>

  Without a root the tree grows below the page carrying the macro, which is what
  the macro does in Confluence. A root title names another page of the same
  space; a tree whose root the mirror does not hold — or whose root this page's
  readers may not open — says so instead of drawing an empty tree, because the
  two are different answers.

  The subtree is a column on every page (`pages.ancestors`), so it is one
  statement however deep it is (`Mirror.descendants/2`), and it arrives in level
  order, so grouping by parent keeps the title order it was read in. A descendant
  those readers may not open is left out: the macro is resolved once for every
  reader, and a tree is exactly where a restriction would leak.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case root(attrs, context) do
      {:ok, root} ->
        tree(context, root, attrs)

      :error ->
        [Nodes.notice("The page tree's root is not in the mirror, or not readable here.")]
    end
  end

  defp root(attrs, context) do
    case title(attrs) do
      nil -> {:ok, context.page}
      title -> context.source.page_by_title(context.page, title)
    end
  end

  defp title(attrs) do
    case attrs |> Map.get("root", "") |> String.trim() do
      "" -> nil
      title -> title
    end
  end

  defp tree(context, root, attrs) do
    pages =
      context.source.descendants(context.page, root,
        limit: Attributes.int(attrs, "limit", 50, 1..200)
      )

    case pages do
      [] -> [Nodes.empty("This page tree has no pages below its root.")]
      pages -> [Nodes.heading("Page tree"), nested(root, pages)]
    end
  end

  defp nested(root, pages) do
    by_parent = Enum.group_by(pages, & &1.parent_id)

    {"ul", [{"class", "mirror-tree"}], items(by_parent[root.id] || [], by_parent)}
  end

  defp items(pages, by_parent) do
    Enum.map(pages, fn page ->
      {"li", [], [Nodes.link(page) | beneath(by_parent[page.id] || [], by_parent)]}
    end)
  end

  defp beneath([], _by_parent), do: []

  defp beneath(pages, by_parent),
    do: [{"ul", [{"class", "mirror-tree"}], items(pages, by_parent)}]
end
