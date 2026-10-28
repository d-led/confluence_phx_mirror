defmodule ConfluencePhxMirror.Mcp.Tools.Pages do
  @moduledoc """
  Tools about pages: reading one, and walking the hierarchy around it.

  Every page a caller names — by id, by URL, or by title and space — is checked
  with `Authorization.can_read_page?/2` before anything is returned, and every
  list is narrowed inside its query with `restrict_pages/2`, the same functions
  the HTML pages and the JSON API use. The error for a page that exists but is
  restricted is word for word the error for a page that does not exist, so a
  tool call cannot be used to confirm that a restricted page is there.
  """

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mcp.{Args, Links, Markdown, PageRef}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Publishing

  # A malformed `parent_id` chain would otherwise recurse until the process
  # dies; the sync resolves parents into a tree, so this is a guard, not a rule.
  @max_depth 32

  @naming "Provide `page_id` (a Confluence content id or a page URL), or both `title` and `space_key`."

  @doc "`confluence_get_page`: one page, as Markdown or storage format."
  def get(args, scope) do
    with {:ok, page} <- resolve(args, scope),
         {:ok, metadata?} <- Args.boolean(args, "include_metadata", true),
         {:ok, markdown?} <- Args.boolean(args, "convert_to_markdown", true) do
      text =
        ["# " <> page.title, metadata(page, metadata?), body(page, markdown?)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      {:ok, %{text: text, structured: summary(page) |> Map.put("format", format(markdown?))}}
    end
  end

  @doc "`confluence_get_page_children`: the pages directly below one."
  def children(args, scope) do
    with {:ok, parent} <- resolve(args, scope, "parent_id"),
         {:ok, start} <- Args.integer(args, "start", default: 0, min: 0, max: 10_000),
         {:ok, limit} <- Args.integer(args, "limit", default: 25, min: 1, max: 100),
         {:ok, content?} <- Args.boolean(args, "include_content", false),
         {:ok, markdown?} <- Args.boolean(args, "convert_to_markdown", true) do
      children =
        parent
        |> Mirror.children(filter: restrict(scope), limit: start + limit)
        |> Enum.drop(start)

      {:ok,
       %{
         text: children_text(parent, children, content?, markdown?),
         structured: %{
           "parent" => summary(parent),
           "children" => Enum.map(children, &summary/1)
         }
       }}
    end
  end

  @doc "`confluence_get_page_ancestors`: the trail down to a page, root first."
  def ancestors(args, scope) do
    with {:ok, page} <- resolve(args, scope) do
      ancestors = Mirror.ancestor_pages(page, filter: restrict(scope))

      {:ok,
       %{
         text: ancestors_text(page, ancestors),
         structured: %{
           "page" => summary(page),
           "ancestors" => Enum.map(ancestors, &summary/1)
         }
       }}
    end
  end

  @doc "`confluence_get_page_descendants`: every page below one, level by level."
  def descendants(args, scope) do
    with {:ok, page} <- resolve(args, scope),
         {:ok, start} <- Args.integer(args, "start", default: 0, min: 0, max: 10_000),
         {:ok, limit} <- Args.integer(args, "limit", default: 25, min: 1, max: 100) do
      %{items: items, total: total} =
        Mirror.descendants(page, start: start, limit: limit, filter: restrict(scope))

      {:ok,
       %{
         text: descendants_text(page, items, total, start, limit),
         structured: %{
           "page" => summary(page),
           "descendants" => Enum.map(items, &subtree_entry(&1, page)),
           "total" => total,
           "start" => start,
           "limit" => limit
         }
       }}
    end
  end

  @doc "`confluence_get_space_page_tree`: the hierarchy of a whole space."
  def tree(args, scope) do
    with {:ok, key} <- Args.required(args, "space_key"),
         {:ok, limit} <- Args.integer(args, "limit", default: 200, min: 1, max: 1000) do
      space_key = String.upcase(key)

      case Mirror.find_space(space_key) do
        {:ok, space} -> tree_of(space, scope, limit)
        {:error, :not_found} -> {:error, "Space #{space_key} is not mirrored."}
      end
    end
  end

  @doc "`confluence_get_backlinks`: the pages that link to one."
  def backlinks(args, scope) do
    with {:ok, page} <- resolve(args, scope),
         {:ok, limit} <- Args.integer(args, "limit", default: 25, min: 1, max: 100) do
      links = page |> Mirror.backlinks(filter: restrict(scope)) |> Enum.take(limit)

      {:ok,
       %{
         text: backlinks_text(page, links),
         structured: %{"page" => summary(page), "backlinks" => Enum.map(links, &summary/1)}
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Naming and checking a page
  # ---------------------------------------------------------------------------

  @doc """
  The page a tool call names, if the reader may open it.

  `key` is the argument that carries the reference — `page_id` almost
  everywhere, `parent_id` on the children tool — because a client reading the
  schema should not have to learn a second name for the same thing.
  """
  @spec resolve(map(), ConfluencePhxMirror.Accounts.Scope.t(), String.t()) ::
          {:ok, ConfluencePhxMirror.Mirror.Page.t()} | {:error, String.t()}
  def resolve(args, scope, key \\ "page_id") do
    with {:ok, reference} <- Args.optional(args, key) do
      cond do
        reference -> by_reference(reference, scope, key)
        key == "page_id" -> by_title(args, scope)
        true -> {:error, "`#{key}` is required: a Confluence content id or a page URL."}
      end
    end
  end

  @doc "The narrowing every page list applies, for the reader's scope."
  @spec restrict(ConfluencePhxMirror.Accounts.Scope.t()) :: (Ecto.Queryable.t() ->
                                                               Ecto.Queryable.t())
  def restrict(scope), do: &Authorization.restrict_pages(&1, scope)

  @doc "The fields a list entry carries, also used as a tool's structured content."
  @spec summary(ConfluencePhxMirror.Mirror.Page.t()) :: map()
  def summary(page) do
    %{
      "id" => to_string(page.confluence_id),
      "title" => page.title,
      "type" => page.type,
      "space" => page.space.key,
      "url" => Links.page(page),
      "updated" => iso(page.external_updated_at)
    }
  end

  @doc "An ISO 8601 timestamp, or nil when the mirror does not know one."
  @spec iso(DateTime.t() | nil) :: String.t() | nil
  def iso(nil), do: nil
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # A row of a subtree listing: the summary plus where it sits below the page
  # the call named. `depth` is what the text indents by and `parent` lets a
  # client rebuild the branch from a window that starts midway.
  defp subtree_entry(page, root) do
    Map.merge(summary(page), %{
      "depth" => Page.depth_below(page, root),
      "parent" => parent_content_id(page)
    })
  end

  defp parent_content_id(page) do
    case Page.parent_confluence_id(page) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp by_reference(reference, scope, key) do
    case PageRef.parse(reference) do
      {:ok, {:id, id}} ->
        lookup(fn -> Mirror.find_page(id) end, scope, "Page #{id} is not mirrored.")

      :error ->
        {:error, "`#{key}` must be a Confluence content id or a page URL."}
    end
  end

  defp by_title(args, scope) do
    with {:ok, title} <- present(args, "title"),
         {:ok, space_key} <- present(args, "space_key") do
      space_key = String.upcase(space_key)
      message = "Page #{inspect(title)} is not mirrored in #{space_key}."
      lookup(fn -> Mirror.find_page_by_title(space_key, title) end, scope, message)
    end
  end

  # A reference that is half given is the same as none: say what a full one
  # looks like rather than complaining about one missing field.
  defp present(args, key) do
    case Args.optional(args, key) do
      {:ok, nil} -> {:error, @naming}
      {:ok, value} -> {:ok, value}
    end
  end

  # Not found and not permitted answer the same sentence: the mirror does not
  # confirm that a restricted page exists, here or on any other surface.
  defp lookup(fetch, scope, message) do
    case fetch.() do
      {:ok, page} ->
        if Authorization.can_read_page?(scope, page), do: {:ok, page}, else: {:error, message}

      {:error, :not_found} ->
        {:error, message}
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp format(true), do: "markdown"
  defp format(false), do: "storage"

  defp body(page, true), do: Markdown.page(page)
  defp body(page, false), do: page.body_storage || ""

  defp metadata(_page, false), do: nil

  defp metadata(page, true) do
    [
      "- id: #{page.confluence_id}",
      "- space: #{page.space.key} — #{page.space.name}",
      "- url: #{Links.page(page)}",
      "- type: #{page.type}",
      "- version: #{version(page)}",
      "- updated: #{updated(page)}",
      labels(page),
      attachments(page),
      if(page.external_url, do: "- original: #{page.external_url}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp version(page) do
    case page.version_message do
      nil -> to_string(page.version_number)
      message -> "#{page.version_number} — #{message}"
    end
  end

  defp updated(page) do
    date = iso(page.external_updated_at) || "unknown"

    case Publishing.byline(page.author_name) do
      nil -> date
      byline -> "#{date} by #{byline}"
    end
  end

  defp labels(%{labels: []}), do: nil
  defp labels(page), do: "- labels: " <> Enum.join(page.labels, ", ")

  # A model that does not know a page has files will never ask for them, and
  # the names are cheap: one indexed query on a page it has already loaded.
  defp attachments(page) do
    case Mirror.attachments(page) do
      [] -> nil
      files -> "- attachments: " <> Enum.map_join(files, ", ", & &1.filename)
    end
  end

  defp children_text(parent, [], _content?, _markdown?) do
    "No child pages of #{parent.title} (id #{parent.confluence_id}) that you may read."
  end

  defp children_text(parent, children, false, _markdown?) do
    heading(parent, children) <>
      "\n\n" <>
      Enum.map_join(children, "\n", fn child ->
        "- #{child.title} (id #{child.confluence_id})\n  #{Links.page(child)}"
      end)
  end

  defp children_text(parent, children, true, markdown?) do
    heading(parent, children) <>
      "\n\n" <>
      Enum.map_join(children, "\n\n", fn child ->
        "## #{child.title} (id #{child.confluence_id})\n" <>
          "#{Links.page(child)}\n\n#{body(child, markdown?)}"
      end)
  end

  defp heading(parent, children) do
    "Children of #{parent.title} (id #{parent.confluence_id}) — #{length(children)}:"
  end

  defp ancestors_text(page, []) do
    "#{page.title} (id #{page.confluence_id}) is a root page; it has no ancestors."
  end

  defp ancestors_text(page, ancestors) do
    "Ancestors of #{page.title} (id #{page.confluence_id}), root first:\n\n" <>
      Enum.map_join(Enum.with_index(ancestors, 1), "\n", fn {ancestor, index} ->
        "#{index}. #{ancestor.title} (id #{ancestor.confluence_id})\n   #{Links.page(ancestor)}"
      end)
  end

  defp descendants_text(page, [], _total, _start, _limit) do
    "No pages below #{page.title} (id #{page.confluence_id}) that you may read."
  end

  defp descendants_text(page, items, total, start, limit) do
    "Pages below #{page.title} (id #{page.confluence_id}) — #{total} in all, " <>
      window(items, total, start, limit) <>
      ":\n\n" <> Enum.map_join(items, "\n", &descendant_line(&1, page))
  end

  # An indented line per page: the indentation is the depth the payload also
  # carries, so the model reads the shape without decoding numbers.
  defp descendant_line(item, root) do
    indent = String.duplicate("  ", Page.depth_below(item, root) - 1)
    indent <> "- #{item.title} (id #{item.confluence_id})\n" <> indent <> "  " <> Links.page(item)
  end

  # A branch is as long as the docs under it, so every answer says how much of
  # it this window holds and how to ask for the rest.
  defp window(items, total, start, limit) do
    shown = "showing #{start + 1}–#{start + length(items)}"
    remaining = total - start - length(items)

    if remaining > 0 do
      "#{shown}, #{remaining} more — call again with start=#{start + limit}"
    else
      shown
    end
  end

  defp backlinks_text(page, []) do
    "No pages link to #{page.title} (id #{page.confluence_id}) that you may read."
  end

  defp backlinks_text(page, links) do
    "Pages linking to #{page.title} (id #{page.confluence_id}) — #{length(links)}:\n\n" <>
      Enum.map_join(links, "\n", fn link ->
        "- #{link.title} (id #{link.confluence_id}) — #{link.space.key}\n  #{Links.page(link)}"
      end)
  end

  # ---------------------------------------------------------------------------
  # The space tree
  # ---------------------------------------------------------------------------

  defp tree_of(space, scope, limit) do
    if Authorization.can_read_space?(scope, space) do
      %{rows: rows, truncated?: truncated?} =
        Mirror.space_tree(space.id, limit: limit, filter: restrict(scope))

      entries = forest(rows)

      {:ok,
       %{
         text: tree_text(space, entries, truncated?),
         structured: %{
           "space" => %{"key" => space.key, "name" => space.name},
           "pages" => Enum.map(entries, fn {row, depth} -> tree_entry(row, space, depth) end),
           "truncated" => truncated?
         }
       }}
    else
      {:error, "Space #{space.key} is not mirrored."}
    end
  end

  # A page whose parent the reader may not see is drawn where its nearest
  # visible ancestor would be — as a root — so an indentation level never
  # announces a branch the reader cannot open.
  defp forest(rows) do
    known = Map.new(rows, &{&1.id, true})
    children = Enum.group_by(rows, &visible_parent(&1, known))
    flatten(Map.get(children, :root, []), 0, children)
  end

  defp visible_parent(row, known) do
    if Map.has_key?(known, row.parent_id), do: row.parent_id, else: :root
  end

  defp flatten(rows, depth, children) do
    Enum.flat_map(rows, fn row -> [{row, depth} | descend(row, depth, children)] end)
  end

  defp descend(_row, depth, _children) when depth >= @max_depth, do: []

  defp descend(row, depth, children) do
    flatten(Map.get(children, row.id, []), depth + 1, children)
  end

  defp tree_text(space, [], _truncated?) do
    "No pages in #{space.name} (#{space.key}) that you may read."
  end

  defp tree_text(space, entries, truncated?) do
    "Page tree of #{space.name} (#{space.key}) — #{length(entries)} pages" <>
      if(truncated?, do: " (first #{length(entries)})", else: "") <>
      ":\n\n" <>
      Enum.map_join(entries, "\n", fn {row, depth} ->
        "#{String.duplicate("  ", depth)}- #{row.title} (id #{row.confluence_id})"
      end)
  end

  defp tree_entry(row, space, depth) do
    %{
      "id" => to_string(row.confluence_id),
      "title" => row.title,
      "type" => row.type,
      "depth" => depth,
      "url" => Links.page(Map.put(row, :space, space)),
      "updated" => iso(row.external_updated_at)
    }
  end
end
