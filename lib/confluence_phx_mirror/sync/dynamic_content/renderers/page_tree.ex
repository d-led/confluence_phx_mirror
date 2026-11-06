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

  The editor's own shape is the one to read, though. A content tree inserted in
  Confluence writes its root as a link — `@home` for the space's top page — the
  space key beside it (`spaces`), and the level the site folds open
  (`startDepth`). `@home` is not a title, so a renderer that read it as one
  answered "the root is not in the mirror" for every tree a person inserts; it is
  asked of the port instead, which is where the audience rule also lives for a
  tree that names another space.

  `startDepth` is deliberately not a depth the mirror draws. It says how much of
  the tree the *site* shows folded open, and the mirror has no chevrons to open
  the rest with: a tree that stopped at level 1 would be a root and nothing else,
  which is exactly what a reader comes to the macro to get past. So every level
  the mirror holds is drawn.

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

  # A root is one of three things: nothing (this page), the space's home page
  # (`@home`), or a page by title — which a `spaces` parameter moves to another
  # space.
  defp root(attrs, context) do
    space = space(attrs)

    case title(attrs) do
      nil -> own_root(space, context)
      title -> resolve(title, space, context)
    end
  end

  defp own_root(nil, context), do: {:ok, context.page}
  defp own_root(space, context), do: context.source.home_page(context.page, space)

  defp resolve(title, space, context) do
    if String.downcase(title) == "@home",
      do: context.source.home_page(context.page, space),
      else: context.source.page_by_title(context.page, qualified(title, space))
  end

  # Confluence writes a page in another space as `KEY/Page Title`, which is the
  # form the port reads.
  defp qualified(title, nil), do: title
  defp qualified(title, space), do: "#{space}/#{title}"

  defp space(attrs), do: attrs |> Attributes.list("spaces") |> List.first()

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
