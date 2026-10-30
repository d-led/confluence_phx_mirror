defmodule ConfluencePhxMirror.Export do
  @moduledoc """
  Exports of the mirror: Markdown, and the mirror as a static site.

  A page exports as one `.md` file, or — when the files it links to have to
  travel with it — as a small ZIP holding the Markdown and an `attachments/`
  folder beside it. A space exports as a ZIP containing a folder tree that
  mirrors the page hierarchy, one Markdown file per page, and each page's
  attachments next to it. Links between pages and to attachments are rewritten
  to relative paths, so the archive works offline.

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
  alias ConfluencePhxMirror.Mirror.{Attachment, Page, Space, URLs}
  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirrorWeb.Skins

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
    ctx = Map.put(ctx, :source_url, page.external_url)

    front_matter(page) <> "\n" <> Markdown.from_html(page.body_export, ctx)
  end

  @doc "Filename offered to the browser for one page."
  def page_filename(%Page{} = page), do: page_name(page) <> ".md"

  @doc """
  Filename offered for one page's Markdown archive.

      architecture_overview_markdown_20261028T101530Z.zip
  """
  @spec page_archive_name(Page.t(), DateTime.t()) :: String.t()
  def page_archive_name(%Page{} = page, at \\ DateTime.utc_now()),
    do: download_name([page_name(page), "markdown"], at) <> ".zip"

  # A page's name in a file name: the one `.md` file and the archive around it
  # are the same page, so they are spelled the same way.
  defp page_name(%Page{} = page), do: slug(page.title, "page_#{page.confluence_id}")

  @doc """
  One page as a ZIP: the Markdown, and beside it an `attachments/` folder with
  every file the page's body links to.

  One `.md` file names its images and its file links but carries none of them,
  so a Markdown viewer paints a broken picture. This archive is the same
  Markdown with those files next to it, which is all a viewer needs to show the
  page as it reads — the image, the PDF, the CSV — with no mirror and no
  network.

  The files are the ones the body points at. A file another page owns is carried
  too: the mirror holds it, the link was rewritten to the mirror's own download
  path when it resolved, and a reader who opens the zip wants the pictures more
  than they want a citation of who owned them.
  """
  @spec page_archive(Page.t()) :: Enumerable.t()
  def page_archive(%Page{} = page) do
    files = page |> referenced_files() |> named_files()

    Stream.concat(
      [{page_filename(page), fn -> page_markdown(page, attachments_ctx(files)) end}],
      Stream.map(files, fn {file, path} -> {path, fn -> read_blob(file.blob_key) end} end)
    )
  end

  defp attachments_ctx(files) do
    %{attachments: Map.new(files, fn {file, path} -> {attachment_url(file), path} end)}
  end

  @doc "Filename offered to the browser for a space archive."
  def archive_name(%Space{} = space, at \\ DateTime.utc_now()),
    do: download_name([space_name(space), "markdown"], at) <> ".zip"

  @doc """
  The mirror as a static site: every space the reader may see, as HTML pages,
  Markdown and attachments.

  Personal spaces are left out unless an administrator asks for them
  (`export.personal_spaces`, seeded by `CM_EXPORT_PERSONAL_SPACES`). A personal
  space is somebody's own corner of the site — drafts, notes, half-finished
  pages — and a site archive is a file that leaves the building; one space's own
  archive (`space_site_archive/2`) is unaffected, because asking for that one by
  name is not an accident.

  See `ConfluencePhxMirror.Export.Site` for the shape of the archive and the
  rules its links follow.
  """
  @spec site_archive(Scope.t(), keyword()) :: Enumerable.t()
  def site_archive(%Scope{} = scope, opts \\ []) do
    scope
    |> Authorization.readable_spaces()
    |> without_personal_spaces()
    |> Site.archive(scope, opts)
  end

  defp without_personal_spaces(spaces) do
    if Settings.export_personal_spaces?() do
      spaces
    else
      Enum.reject(spaces, &Authorization.personal_space?/1)
    end
  end

  @doc "One space as a standalone static site."
  @spec space_site_archive(Space.t(), Scope.t(), keyword()) :: Enumerable.t()
  def space_site_archive(%Space{} = space, %Scope{} = scope, opts \\ []) do
    Site.archive([space], scope, opts)
  end

  @doc """
  Filename offered for the whole-site static archive.

      confluence_mirror_site_20261026T101530Z.zip
  """
  @spec site_archive_name(DateTime.t()) :: String.t()
  def site_archive_name(at \\ DateTime.utc_now()),
    do: download_name([slug(Sites.name(), "confluence_mirror"), "site"], at) <> ".zip"

  @doc """
  The name of the whole site's prepared archive on disk.

  One name, so that every ask for the prepared export — the screen that builds
  it and the request that sends it — is talking about the same file.
  """
  @spec site_artifact() :: String.t()
  def site_artifact, do: "site.zip"

  @doc """
  The content a prepared archive is a copy of.

  An archive is worth keeping exactly as long as the mirror it copied has not
  moved, so this names that state: the newest page (by id, so an insert shows),
  the newest change to any page, space or attachment, and the two settings that
  change what an archive *contains* rather than what it says. Two calls with
  nothing mirrored or configured in between answer the same term.

  The aggregates are index maxima, so asking costs one query and no table walk;
  `Export.Artifact` compares the answer with the one a finished build recorded.
  """
  @spec site_archive_version() :: term()
  def site_archive_version do
    state = Mirror.content_state()

    {state.page_id, state.page_at, state.space_at, state.attachment_at,
     Settings.export_personal_spaces?(), Skins.theme(), Sites.name()}
  end

  @doc """
  Filename offered for one space's static archive.

      engineering_handbook_site_20261026T101530Z.zip
  """
  @spec space_site_archive_name(Space.t(), DateTime.t()) :: String.t()
  def space_site_archive_name(%Space{} = space, at \\ DateTime.utc_now()),
    do: download_name([space_name(space), "site"], at) <> ".zip"

  # A space's own name, or its key when the name is written in a script a file
  # name cannot carry: `Привет` becomes `privet`, not `untitled`.
  defp space_name(%Space{} = space), do: slug(space.name, slug(space.key, "space"))

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
      target = folder <> "/attachments/" <> local_name(attachment)
      {target, fn -> read_blob(attachment.blob_key) end}
    end)
  end

  # ---------------------------------------------------------------------------
  # One page's files
  # ---------------------------------------------------------------------------

  # The sync rewrote every file the body mentions — an image or a link to one —
  # to the mirror's own download path, so the body is the complete list of
  # files the page shows. The attachment's id is whatever Confluence spelled it
  # as: `9001` on a hand-written snapshot, `att426191` on Cloud, which numbers
  # pages but prefixes its files.
  @attachment_path ~r{/attachments/[^/?#"'\s]+/[^/?#"'\s]+/([^/?#"'\s]+)/[^/?#"'\s]+}

  defp referenced_files(%Page{} = page) do
    page.body_export
    |> to_string()
    |> then(&Regex.scan(@attachment_path, &1))
    |> Enum.map(fn [_, confluence_id] -> confluence_id end)
    |> Enum.uniq()
    |> Mirror.attachments_by_confluence_ids()
  end

  # The path the body links to, built the way the sync built it, so the
  # Markdown converter finds the file under the href it reads.
  defp attachment_url(%Attachment{} = file) do
    URLs.attachment_path(
      file.page.space.key,
      file.page.confluence_id,
      file.confluence_id,
      file.filename
    )
  end

  # One folder holds every file, and two of them can want the same name: a
  # comment's screenshot and the page's own. The attachment's id keeps both, and
  # only shows up where a name really repeats.
  defp named_files(files) do
    names = Enum.frequencies_by(files, &local_name/1)

    Enum.map(files, fn file ->
      name = local_name(file)
      name = if names[name] > 1, do: disambiguated_name(file, name), else: name
      {file, "attachments/" <> name}
    end)
  end

  defp local_name(%Attachment{} = file), do: Key.sanitise_filename(file.filename)

  defp disambiguated_name(%Attachment{} = file, name) do
    Path.rootname(name) <> "-" <> to_string(file.confluence_id) <> Path.extname(name)
  end

  # An attachment whose bytes never landed keeps its entry, empty: the archive
  # is a copy of the mirror, and a missing file is the mirror saying so.
  defp read_blob(nil), do: ""

  defp read_blob(key) do
    case Store.read(key) do
      {:ok, data} -> data
      {:error, _missing} -> ""
    end
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
    author: #{inspect(Publishing.byline(page.author_name) || "unknown")}
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

  # A download's name says what the file is and when it was made:
  # `dled_site_20261026T101530Z.zip`. Underscores only — a save dialog, an
  # archive tool and a shared drive all keep them as they are.
  defp download_name(parts, at) do
    stamp = at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    (Enum.map(parts, &slug/1) ++ [stamp]) |> Enum.join("_")
  end

  # Lowercase words joined by underscores, so `My first space` and
  # `Café: notes/ideas` both become names nobody has to quote.
  defp slug(value, fallback \\ "archive") do
    value
    |> to_string()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9]+/u, "_")
    |> String.trim("_")
    |> String.downcase()
    |> String.slice(0, 80)
    |> String.trim("_")
    |> case do
      "" -> slug(fallback)
      safe -> safe
    end
  end
end
