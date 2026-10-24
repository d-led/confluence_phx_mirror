defmodule ConfluencePhxMirror.Export do
  @moduledoc """
  Exports of the mirror: Markdown, and the mirror as a static site.

  A page exports as one `.md` file; a space exports as a ZIP containing a
  folder tree that mirrors the page hierarchy, one Markdown file per page, and
  each page's attachments next to it. Links between pages and to attachments
  are rewritten to relative paths, so the archive works offline.

  `ConfluencePhxMirror.Export.Site` is the same idea for readers who want the
  pages themselves: HTML, the site's theme, an offline search index and the
  Markdown beside each page.

  Every archive is streamed: pages are converted one at a time and attachments
  are read from the blob store only while they are written, so a large space
  never has to fit in memory.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Export.Markdown
  alias ConfluencePhxMirror.Export.Site
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Page, Space, URLs}
  alias ConfluencePhxMirror.Sites

  @doc "Markdown of one page, with Confluence metadata as front matter."
  @spec page_markdown(Page.t()) :: String.t()
  def page_markdown(%Page{} = page), do: page_markdown(page, %{})

  @doc """
  Markdown of one page whose links have already been planned.

  `ctx` is `ConfluencePhxMirror.Export.Markdown`'s context — the archive's page
  files and this page's attachments — so the Markdown written beside a page in
  the static site points at the files that are actually there.
  """
  @spec page_markdown(Page.t(), map()) :: String.t()
  def page_markdown(%Page{} = page, ctx) do
    front_matter(page) <> "\n" <> Markdown.from_html(page.body_export, ctx)
  end

  @doc "Filename offered to the browser for one page."
  def page_filename(%Page{} = page), do: sanitise(page.title) <> ".md"

  @doc "Filename offered to the browser for a space archive."
  def archive_name(%Space{} = space), do: sanitise(space.name) <> ".zip"

  @doc """
  The mirror as a static site: every space the reader may see, as HTML pages,
  Markdown and attachments.

  See `ConfluencePhxMirror.Export.Site` for the shape of the archive and the
  rules its links follow.
  """
  @spec site_archive(Scope.t(), keyword()) :: Enumerable.t()
  def site_archive(%Scope{} = scope, opts \\ []) do
    scope |> Authorization.readable_spaces() |> Site.archive(scope, opts)
  end

  @doc "One space as a standalone static site."
  @spec space_site_archive(Space.t(), Scope.t(), keyword()) :: Enumerable.t()
  def space_site_archive(%Space{} = space, %Scope{} = scope, opts \\ []) do
    Site.archive([space], scope, opts)
  end

  @doc "Filename offered for the whole-site static archive."
  def site_archive_name, do: sanitise(Sites.name()) <> " site.zip"

  @doc "Filename offered for one space's static archive."
  def space_site_archive_name(%Space{} = space), do: sanitise(space.name) <> " site.zip"

  @doc """
  Stream of `{path_in_zip, data_or_fun}` entries for a space archive.

  With a scope, the archive holds only the pages that reader may open — the
  space check is not enough, because Confluence restricts single pages inside a
  space that is otherwise readable. `nil` keeps every page and is for callers
  that have already decided (an administrator, a test).
  """
  @spec space_archive(Space.t(), Scope.t() | nil) :: Enumerable.t()
  def space_archive(%Space{} = space, scope \\ nil) do
    pages = space.id |> Mirror.list_pages() |> readable(scope)
    plan = plan_files(space, pages)

    index = {plan.index, index_markdown(space, pages, plan)}

    page_entries =
      Stream.map(pages, fn page ->
        {plan.by_id[page.id], page_markdown_with_links(page, plan, space)}
      end)

    attachment_entries =
      Stream.flat_map(pages, fn page -> attachment_entries(page, plan.by_id[page.id]) end)

    Stream.concat([index], Stream.concat(page_entries, attachment_entries))
  end

  defp readable(pages, nil), do: pages
  defp readable(pages, %Scope{} = scope), do: Authorization.readable_pages(scope, pages)

  # ---------------------------------------------------------------------------
  # Path planning
  # ---------------------------------------------------------------------------
  defp plan_files(space, pages) do
    root = sanitise(space.name)
    by_confluence = Map.new(pages, &{&1.confluence_id, &1})

    by_id =
      Map.new(pages, fn page ->
        folder = page_folder(page, by_confluence, root)
        {page.id, folder <> "/" <> sanitise(page.title) <> ".md"}
      end)

    %{
      index: root <> "/index.md",
      by_id: by_id,
      by_confluence: Map.new(pages, &{&1.confluence_id, by_id[&1.id]}),
      root: root
    }
  end

  defp page_folder(%Page{type: "blogpost"}, _by_confluence, root), do: root <> "/Blog"
  defp page_folder(%Page{status: "archived"}, _by_confluence, root), do: root <> "/Archived"

  defp page_folder(%Page{} = page, _by_confluence, root)
       when page.type == "page" and page.ancestors == [] and page.status != "archived",
       do: root

  defp page_folder(page, by_confluence, root) do
    ancestors =
      page.ancestors
      |> Enum.map(&by_confluence[&1])
      |> Enum.reject(&(is_nil(&1) or root_page?(&1)))
      |> Enum.map(&sanitise(&1.title))

    Enum.join([root | ancestors] ++ [sanitise(page.title)], "/")
  end

  # The space's home page is the archive's root folder, not a folder inside it.
  defp root_page?(%Page{type: "page", ancestors: []}), do: true
  defp root_page?(_page), do: false

  # ---------------------------------------------------------------------------
  # Entries
  # ---------------------------------------------------------------------------

  defp page_markdown_with_links(page, plan, space) do
    attachments =
      page
      |> Mirror.attachments()
      |> Map.new(fn attachment ->
        {URLs.attachment_path(
           space.key,
           page.confluence_id,
           attachment.confluence_id,
           attachment.filename
         ), "attachments/" <> Key.sanitise_filename(attachment.filename)}
      end)

    ctx = %{
      page_files: plan.by_confluence,
      current_folder: Path.dirname(plan.by_id[page.id]),
      attachments: attachments
    }

    page_markdown(page, ctx)
  end

  defp attachment_entries(page, file) do
    folder = Path.dirname(file)

    page
    |> Mirror.attachments()
    |> Enum.map(fn attachment ->
      name = Key.sanitise_filename(attachment.filename)
      target = folder <> "/attachments/" <> name
      blob_key = attachment.blob_key

      {target,
       fn ->
         with key when is_binary(key) <- blob_key,
              {:ok, data} <- Store.read(key) do
           data
         else
           _ -> ""
         end
       end}
    end)
  end

  defp index_markdown(space, pages, plan) do
    root = plan.root

    entries =
      Enum.map_join(pages, "", fn page ->
        "- [#{page.title}](#{Path.relative_to(plan.by_id[page.id], root)})\n"
      end)

    """
    # #{space.name} (#{space.key})

    #{space.description || "No description in Confluence."}

    ## Pages

    #{entries}
    Exported from the Confluence mirror, normalised #{Date.utc_today()}.
    """
  end

  # ---------------------------------------------------------------------------
  # Front matter
  # ---------------------------------------------------------------------------

  defp front_matter(page) do
    """
    ---
    title: #{inspect(page.title)}
    type: #{page.type}
    space: #{inspect(page.space.key)}
    confluence_id: #{page.confluence_id}
    version: #{page.version_number}
    author: #{inspect(page.author_name || "unknown")}
    updated: #{iso8601(page.external_updated_at)}
    url: #{inspect(page.external_url)}
    labels: [#{Enum.join(page.labels || [], ", ")}]
    ---
    """
  end

  defp iso8601(nil), do: ""
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # Keeps folder names recognisable while staying safe on every filesystem.
  defp sanitise(value) do
    value
    |> to_string()
    |> String.replace(~r/[<>:"\/\\|?*\x00-\x1F]+/u, "-")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim(" .-")
    |> String.slice(0, 80)
    |> case do
      "" -> "Untitled"
      safe -> safe
    end
  end
end
