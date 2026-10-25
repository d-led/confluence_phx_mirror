defmodule ConfluencePhxMirror.Export.Site do
  @moduledoc """
  The mirror as a static site: pages, their attachments and the site's theme,
  as files that work from any folder without a server.

  The archive is one shape whether it holds one space or all of them:

      index.html                          every space in the archive
      search.html                         search over this copy, offline
      labels/index.html                   every label, with what it holds
      labels/<label>.html                 every page carrying one label
      spaces/<KEY>/index.html             a space: description, categories, page tree
      spaces/<KEY>/pages/<id>.html        one page: body, files and discussion
      spaces/<KEY>/pages/<id>.md          the same page as Markdown
      spaces/<KEY>/icon.<ext>             the space's icon, when it has one
      attachments/<KEY>/<page>/<file>     one file per mirrored attachment
      assets/site.css                     the mirror's own stylesheet
      assets/search.json                  the search index, for other tools
      assets/search.js                    the matcher search.html runs

  Page paths carry Confluence's id, not the title, so two pages whose titles
  collide cannot overwrite each other; the title is on the page itself.

  Cross-links follow the rule the mirror already applies, one step further out:
  a target the archive carries becomes a relative file, a target it does not —
  a restricted page in a reader's copy, another space's page in a one-space
  archive — goes back to Confluence.

  Bodies are not held in memory: the page is read while its entry is written,
  exactly like `ConfluencePhxMirror.Export.space_archive/2`. The search index
  is the one exception — an index is a single file — and it carries only ids,
  titles and an excerpt of each page's text.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.Site.{Chrome, Content, HTML, Search}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Page, Space, URLs}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirrorWeb.Skins

  @stylesheet_path "priv/static/assets/css/app.css"
  @description_chars 200
  # What a search document carries of a page's text: enough to find it by a
  # phrase and to show why it matched, not a second copy of the wiki. The
  # truncation is done by Postgres, so the plan never holds a whole body.
  @excerpt_chars 400
  # The label pages live one folder down, so every link they build is relative
  # to `labels/`, not to the archive root.
  @labels_prefix "../"

  @type plan :: %{
          space: Space.t(),
          pages: [map()],
          by_id: %{integer() => map()},
          children: %{(integer() | nil) => [map()]},
          tree: [map()]
        }

  @doc """
  Stream of `{path_in_zip, data_or_fun}` entries for `spaces` as one site.

  A space the reader may not see is left out, and so is every page they may not
  open: an export is another way of reading, so it answers to the same rules.

  Options:

    * `:stylesheet` — the site's CSS. Defaults to `stylesheet/0`, the compiled
      stylesheet this instance serves plus the emitted theme; absent when the
      assets were never built.
    * `:generated_at` — the instant the archive says it was copied.
  """
  @spec archive([Space.t()], Scope.t(), keyword()) :: Enumerable.t()
  def archive(spaces, %Scope{} = scope, opts \\ []) do
    generated = Keyword.get_lazy(opts, :generated_at, &DateTime.utc_now/0)

    plans =
      spaces
      |> Enum.filter(&Authorization.can_read_space?(scope, &1))
      |> Enum.map(&plan(&1, scope))

    Stream.concat(index_entries(plans, generated, opts), page_stream(plans, generated))
  end

  # ---------------------------------------------------------------------------
  # Paths
  # ---------------------------------------------------------------------------

  @doc "The archive's front page."
  def index_path, do: "index.html"

  @doc "A space's front page."
  def space_index_path(space_key), do: "spaces/#{space_key}/index.html"

  @doc "A page, as HTML."
  def page_path(space_key, confluence_id), do: "spaces/#{space_key}/pages/#{confluence_id}.html"

  @doc "A page, as Markdown."
  def markdown_path(space_key, confluence_id), do: "spaces/#{space_key}/pages/#{confluence_id}.md"

  @doc "The archive's search page."
  def search_path, do: "search.html"

  @doc "The search index, for tools that read the archive."
  def search_index_path, do: "assets/search.json"

  @doc "The search page's matcher."
  def search_script_path, do: "assets/search.js"

  @doc "Folding the page tree and switching the theme."
  def site_script_path, do: "assets/site.js"

  @doc "The pinned theme variant, applied before the first paint."
  def theme_script_path, do: "assets/theme.js"

  @doc "The archive's label catalogue."
  def labels_path, do: "labels/index.html"

  @doc "Everything carrying one label."
  def label_path(label), do: "labels/#{label_key(label)}.html"

  @doc "An attachment's bytes, named the way the page links to them."
  def attachment_path(space_key, page_confluence_id, attachment_id, filename) do
    "attachments/#{space_key}/#{page_confluence_id}/#{attachment_id}/" <>
      Key.sanitise_filename(filename)
  end

  @doc """
  The relative way from a file back to the archive root.

      iex> prefix("index.html")
      ""
      iex> prefix("spaces/ENG/index.html")
      "../../"
      iex> prefix("spaces/ENG/pages/1002.html")
      "../../../"
  """
  @spec prefix(String.t()) :: String.t()
  def prefix(file) do
    file
    |> Path.dirname()
    |> String.split("/")
    |> Enum.reject(&(&1 in ["", "."]))
    |> length()
    |> then(&String.duplicate("../", &1))
  end

  @doc """
  The archive's stylesheet: the CSS this instance serves, plus the theme an
  administrator picked, so an exported page is painted like the page it came
  from.

  Empty when the assets were never built (a test run, a bare checkout): the
  archive is still readable, it just is not dressed.
  """
  @spec stylesheet() :: String.t()
  def stylesheet do
    [compiled_stylesheet(), Skins.style()]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp compiled_stylesheet do
    case File.read(Application.app_dir(:confluence_phx_mirror, @stylesheet_path)) do
      {:ok, css} -> css
      {:error, _not_built} -> ""
    end
  end

  @doc """
  The attributes `<html>` needs to paint the site's theme, following the OS.

  `data-theme-name` names the theme for the scripts: a compiled theme is
  switched by rewriting `data-theme` to `light`/`dark`, an emitted one by
  pinning `data-scheme`, and only the page knows which kind it is looking at.
  """
  def html_attributes do
    Map.put(Skins.attributes(Skins.theme(), "system"), "data-theme-name", Skins.theme())
  end

  # ---------------------------------------------------------------------------
  # Entries
  # ---------------------------------------------------------------------------

  defp index_entries(plans, generated, opts) do
    json = plans |> Search.documents() |> Search.json()

    search = [
      {search_path(), fn -> render_search(plans, json, generated) end},
      {search_index_path(), json},
      {search_script_path(), Search.script()}
    ]

    labels = label_entries(plans, generated)
    index = [{index_path(), fn -> render_site(plans, generated) end} | search ++ labels]

    chrome = [
      {site_script_path(), Chrome.script()},
      {theme_script_path(), Chrome.theme_script()}
    ]

    case Keyword.get_lazy(opts, :stylesheet, &stylesheet/0) do
      "" -> index ++ chrome
      css -> index ++ chrome ++ [{"assets/site.css", css}]
    end
  end

  defp page_stream(plans, generated) do
    context = %{
      pages:
        Map.new(
          Enum.flat_map(plans, fn plan ->
            Enum.map(
              plan.pages,
              &{&1.confluence_id, page_path(plan.space.key, &1.confluence_id)}
            )
          end)
        ),
      origins: origins(),
      external: &external_urls/1,
      external_attachment: &external_attachment/2
    }

    # One space at a time, one page at a time: the plan is ids and titles, the
    # bodies are read while their entries are written.
    plans
    |> Stream.flat_map(fn plan ->
      Stream.concat(
        [{space_index_path(plan.space.key), fn -> render_space(plan, generated) end}],
        Stream.concat(icon_entry(plan.space), page_entries(plan, context, generated))
      )
    end)
  end

  defp icon_entry(%Space{icon_blob_key: nil}), do: []

  defp icon_entry(%Space{icon_blob_key: key}) do
    [{key, fn -> read_blob(key) end}]
  end

  defp page_entries(plan, context, generated) do
    Stream.flat_map(plan.pages, &entries_for_page(plan, &1, context, generated))
  end

  defp entries_for_page(plan, row, context, generated) do
    # Read once per page and shared by its two files: the body for the page,
    # the same body converted for the Markdown beside it, and the discussion
    # that hangs off it.
    page = find_page(row.confluence_id)
    files = attachments(page)
    thread = comments(page)
    file = page_path(plan.space.key, row.confluence_id)

    [
      {file, fn -> render_page(plan, row, page, files, thread, context, generated) end},
      {markdown_path(plan.space.key, row.confluence_id),
       fn -> render_markdown(plan, row, page, own_files(files)) end}
    ] ++ Enum.map(files, &attachment_entry(plan, row, &1))
  end

  defp attachment_entry(plan, row, attachment) do
    {attachment_path(
       plan.space.key,
       row.confluence_id,
       attachment.confluence_id,
       attachment.filename
     ), fn -> read_blob(attachment.blob_key) end}
  end

  defp read_blob(nil), do: ""

  defp read_blob(key) do
    case Store.read(key) do
      {:ok, data} -> data
      {:error, _missing} -> ""
    end
  end

  # A label is a way into the archive the space tree cannot give: "everything
  # about deployment", whichever space it lives in. The mirror has a label
  # catalogue; the archive carries the same two screens, built from labels the
  # plan already holds — no query of their own.
  defp label_entries(plans, generated) do
    groups = label_groups(plans)

    [{labels_path(), fn -> render_labels(plans, groups, generated) end}] ++
      Enum.map(groups, fn {key, group} ->
        {label_path(key), fn -> render_label(plans, group, generated) end}
      end)
  end

  defp label_groups(plans) do
    plans
    |> Enum.flat_map(fn plan ->
      Enum.flat_map(plan.pages, fn page ->
        Enum.map(page.labels || [], &{label_key(&1), &1, plan.space, page})
      end)
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {key, entries} -> {key, group(key, entries)} end)
  end

  defp group(_key, entries) do
    pages =
      entries
      |> Enum.map(fn {_key, _label, space, page} ->
        %{
          title: page.title,
          confluence_id: page.confluence_id,
          space_key: space.key,
          space_name: space.name
        }
      end)
      |> Enum.uniq_by(&{&1.space_key, &1.confluence_id})
      |> Enum.sort_by(&{&1.space_name, &1.title})

    %{name: most_common(Enum.map(entries, &elem(&1, 1))), pages: pages}
  end

  # Two spellings can share a file name; the catalogue shows the one most pages
  # carry, so a label reads as the site spells it.
  defp most_common(names) do
    names
    |> Enum.frequencies()
    |> Enum.max_by(fn {name, count} -> {count, name} end)
    |> elem(0)
  end

  defp label_key(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.trim("-")
    |> String.replace(~r/^\.+/, "")
    |> case do
      "" -> "label"
      key -> key
    end
  end

  # ---------------------------------------------------------------------------
  # The plan
  # ---------------------------------------------------------------------------

  @doc """
  What the archive will carry, read without any page body.

  Public so a caller can say how much work an export is before starting it.
  """
  @spec plan(Space.t(), Scope.t()) :: plan()
  def plan(%Space{} = space, %Scope{} = scope) do
    pages = page_rows(space, scope)

    %{
      space: space,
      pages: pages,
      by_id: Map.new(pages, &{&1.confluence_id, &1}),
      children: Enum.group_by(pages, & &1.parent_id),
      tree: tree(pages)
    }
  end

  defp page_rows(space, scope) do
    from(p in Page,
      as: :page,
      where: p.space_id == ^space.id and is_nil(p.deleted_at),
      order_by: [asc: p.title],
      select: %{
        id: p.id,
        confluence_id: p.confluence_id,
        parent_id: p.parent_id,
        title: p.title,
        type: p.type,
        status: p.status,
        labels: p.labels,
        ancestors: p.ancestors,
        external_updated_at: p.external_updated_at,
        text: fragment("left(coalesce(?, ''), ?)", p.body_text, ^@excerpt_chars)
      }
    )
    |> Authorization.restrict_pages(scope)
    |> Repo.all()
  end

  @doc """
  Rows nested the way the page tree is, siblings in title order.

  A page whose parent the archive does not carry (a restricted parent, a broken
  `parent_id`) becomes a root of its own rather than disappearing.
  """
  @spec tree([map()]) :: [map()]
  def tree(rows) do
    ids = MapSet.new(rows, & &1.id)
    children = Enum.group_by(rows, & &1.parent_id)

    roots =
      (children[nil] || []) ++
        Enum.filter(rows, &(not is_nil(&1.parent_id) and not MapSet.member?(ids, &1.parent_id)))

    Enum.map(roots, &node(&1, children))
  end

  defp node(row, children) do
    Map.put(row, :children, Enum.map(children[row.id] || [], &node(&1, children)))
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp render_site(plans, generated) do
    spaces = space_cards(plans, "")

    HTML.site(%{
      title: Sites.name(),
      spaces: spaces,
      page_count: Enum.sum(Enum.map(spaces, & &1.page_count)),
      generated: stamp(generated),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      html_attributes: html_attributes()
    })
    |> to_binary()
  end

  defp render_search(plans, json, generated) do
    spaces = space_cards(plans, "")

    HTML.search(%{
      title: "Search · #{Sites.name()}",
      spaces: spaces,
      page_count: Enum.sum(Enum.map(spaces, & &1.page_count)),
      json: json,
      generated: stamp(generated),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      html_attributes: html_attributes()
    })
    |> to_binary()
  end

  defp render_labels(plans, groups, generated) do
    labels =
      groups
      |> Enum.map(fn {key, group} ->
        %{
          name: group.name,
          href: label_path(key),
          count: length(group.pages),
          spaces: group.pages |> Enum.map(& &1.space_key) |> Enum.uniq() |> length()
        }
      end)
      |> Enum.sort_by(&String.downcase(&1.name))

    HTML.labels(%{
      title: "Labels · #{Sites.name()}",
      prefix: @labels_prefix,
      spaces: space_cards(plans, @labels_prefix),
      labels: labels,
      generated: stamp(generated),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      html_attributes: html_attributes()
    })
    |> to_binary()
  end

  defp render_label(plans, group, generated) do
    pages =
      Enum.map(group.pages, fn page ->
        Map.put(page, :href, @labels_prefix <> page_path(page.space_key, page.confluence_id))
      end)

    HTML.label(%{
      title: "#{group.name} · Labels · #{Sites.name()}",
      prefix: @labels_prefix,
      spaces: space_cards(plans, @labels_prefix),
      label: group.name,
      pages: pages,
      generated: stamp(generated),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      html_attributes: html_attributes()
    })
    |> to_binary()
  end

  defp space_cards(plans, prefix) do
    Enum.map(plans, fn plan ->
      %{
        name: plan.space.name,
        key: plan.space.key,
        href: prefix <> space_index_path(plan.space.key),
        icon: icon_href(plan.space, prefix),
        description: excerpt(plan.space.description),
        page_count: length(plan.pages)
      }
    end)
  end

  # The addresses this site is known by, whose page URLs are the mirror's own
  # pages even when a body spells them out in full.
  defp origins do
    case Sites.current() do
      %{base_url: base_url} when is_binary(base_url) and base_url != "" ->
        uri = URI.parse(base_url)
        origin = "#{uri.scheme}://#{uri.host}"

        [String.trim_trailing(base_url, "/"), origin]
        |> Enum.uniq()

      _no_site_address ->
        []
    end
  end

  defp render_space(plan, generated) do
    prefix = prefix(space_index_path(plan.space.key))

    HTML.space(%{
      title: "#{plan.space.name} · #{Sites.name()}",
      prefix: prefix,
      space: plan.space,
      icon: icon_href(plan.space, prefix),
      tree: tree_nodes(plan, prefix),
      home: home(plan, prefix),
      page_count: length(plan.pages),
      generated: stamp(generated),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      html_attributes: html_attributes()
    })
    |> to_binary()
  end

  defp render_page(plan, row, page, files, thread, context, generated) do
    file = page_path(plan.space.key, row.confluence_id)
    prefix = prefix(file)
    comment_context = Map.put(context, :prefix, prefix)
    comments = comment_thread(thread, comment_context)

    HTML.page(%{
      title: "#{row.title} · #{plan.space.name} · #{Sites.name()}",
      prefix: prefix,
      page: page_data(row, page),
      body: Content.rewrite(page && page.body_export, Map.put(context, :prefix, prefix)),
      updated: stamp(page && page.external_updated_at),
      space_name: plan.space.name,
      space_key: plan.space.key,
      space_href: prefix <> space_index_path(plan.space.key),
      path: path_nodes(plan, row, prefix),
      children: children(plan, row, prefix),
      crumbs: crumbs(plan, row, prefix),
      attachments: attachment_links(plan, row, own_files(files), prefix),
      comments: comments,
      comment_count: Enum.sum(Enum.map(comments, &(1 + length(&1.replies)))),
      original: page && page.external_url,
      markdown_href: prefix <> markdown_path(plan.space.key, row.confluence_id),
      generated: stamp(generated),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      html_attributes: html_attributes()
    })
    |> to_binary()
  end

  defp render_markdown(plan, row, %Page{} = page, attachments) do
    file = markdown_path(plan.space.key, row.confluence_id)

    Export.page_markdown(page, %{
      page_files:
        Map.new(
          plan.pages,
          &{&1.confluence_id, markdown_path(plan.space.key, &1.confluence_id)}
        ),
      current_folder: Path.dirname(file),
      attachments: attachment_paths(plan, row, attachments, prefix(file))
    })
  end

  # A page that was trashed between planning and writing: the archive keeps its
  # place in the tree, and says what it knows.
  defp render_markdown(_plan, row, _page, _attachments) do
    "# #{row.title}\n\nThe page is no longer in the mirror.\n"
  end

  defp page_data(_row, %Page{} = page), do: page

  defp page_data(row, _page),
    do: Map.merge(row, %{author_name: nil, version_number: nil, labels: []})

  # A discussion is roots and one level of replies, the way the reader screen
  # draws it. A comment's body is Confluence HTML like a page's, so it goes
  # through the same rewrite: a link to another page stays inside the archive.
  defp comment_thread(comments, context) do
    replies = Enum.group_by(Enum.reject(comments, &is_nil(&1.parent_id)), & &1.parent_id)

    comments
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.map(fn comment ->
      Map.put(
        comment_data(comment, context),
        :replies,
        Enum.map(replies[comment.id] || [], &comment_data(&1, context))
      )
    end)
  end

  defp comment_data(comment, context) do
    %{
      author: comment.author_name || "Anonymous",
      initial: initial(comment.author_name),
      at: stamp(comment.external_created_at),
      body: Content.rewrite(comment.body_export, context)
    }
  end

  defp initial(nil), do: "?"

  defp initial(name) do
    case name |> to_string() |> String.first() do
      nil -> "?"
      first -> String.upcase(first)
    end
  end

  defp tree_nodes(plan, prefix) do
    Enum.map(plan.tree, &tree_node(plan.space.key, &1, prefix))
  end

  defp tree_node(space_key, row, prefix) do
    %{
      title: row.title,
      confluence_id: row.confluence_id,
      href: prefix <> page_path(space_key, row.confluence_id),
      children: Enum.map(row.children, &tree_node(space_key, &1, prefix))
    }
  end

  # The way from the space's root to this page's parent: what a reader needs to
  # place the page, and O(depth) rather than O(pages in the space).
  defp path_nodes(plan, row, prefix) do
    row.ancestors
    |> Enum.reject(&(&1 == plan.space.homepage_confluence_id))
    |> Enum.map(&plan.by_id[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn ancestor ->
      %{title: ancestor.title, href: prefix <> page_path(plan.space.key, ancestor.confluence_id)}
    end)
  end

  defp children(plan, row, prefix) do
    plan.children
    |> Map.get(row.id, [])
    |> Enum.map(fn child ->
      %{title: child.title, href: prefix <> page_path(plan.space.key, child.confluence_id)}
    end)
  end

  defp crumbs(plan, row, prefix) do
    space = %{
      title: plan.space.name,
      href: prefix <> space_index_path(plan.space.key)
    }

    trail =
      row.ancestors
      |> Enum.reject(&(&1 == plan.space.homepage_confluence_id))
      |> Enum.map(&plan.by_id[&1])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn ancestor ->
        %{
          title: ancestor.title,
          href: prefix <> page_path(plan.space.key, ancestor.confluence_id)
        }
      end)

    [%{title: "All spaces", href: prefix <> index_path()}, space | trail]
  end

  defp home(plan, prefix) do
    case Map.get(plan.by_id, plan.space.homepage_confluence_id) do
      nil -> nil
      row -> %{title: row.title, href: prefix <> page_path(plan.space.key, row.confluence_id)}
    end
  end

  defp icon_href(%Space{icon_blob_key: nil}, _prefix), do: nil
  defp icon_href(%Space{icon_blob_key: key}, prefix), do: prefix <> key

  defp attachment_links(plan, row, attachments, prefix) do
    Enum.map(attachments, fn attachment ->
      %{
        name: attachment.filename,
        href: prefix <> attachment_path_of(plan, row, attachment),
        size: Attachment.human_size(attachment.byte_size)
      }
    end)
  end

  defp attachment_paths(plan, row, attachments, prefix) do
    Map.new(attachments, fn attachment ->
      {URLs.attachment_path(
         plan.space.key,
         row.confluence_id,
         attachment.confluence_id,
         attachment.filename
       ), prefix <> attachment_path_of(plan, row, attachment)}
    end)
  end

  defp attachment_path_of(plan, row, attachment) do
    attachment_path(
      plan.space.key,
      row.confluence_id,
      attachment.confluence_id,
      attachment.filename
    )
  end

  defp to_binary(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  # ---------------------------------------------------------------------------
  # Links back to Confluence
  # ---------------------------------------------------------------------------

  # A link to a page the archive does not carry still has to go somewhere. The
  # page's own URL is what the mirror recorded, so it is the honest answer —
  # one query for the whole page, and usually no rows at all.
  defp external_urls(ids) do
    stored =
      from(p in Page,
        where: p.confluence_id in ^ids,
        select: {p.confluence_id, p.external_url}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(ids, fn id -> {id, Map.get(stored, id) || viewpage_url(id)} end)
  end

  defp viewpage_url(confluence_id) do
    case Sites.url() do
      nil -> "#"
      url -> url <> "/pages/viewpage.action?pageId=#{confluence_id}"
    end
  end

  # A file hanging off a page the archive does not carry has no path inside it.
  # Confluence's own download path is the honest answer where the site has an
  # address; a bundled snapshot has none, and the body's href stays as it is.
  defp external_attachment(page_confluence_id, filename) do
    case Sites.url() do
      nil -> nil
      url -> url <> "/download/attachments/#{page_confluence_id}/#{URI.encode(filename)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Reading and formatting
  # ---------------------------------------------------------------------------

  defp find_page(confluence_id) do
    case Mirror.find_page(confluence_id) do
      {:ok, page} -> page
      {:error, :not_found} -> nil
    end
  end

  # Every file the page carries, including the ones a comment added: a
  # screenshot pasted into a reply is content of the page it hangs off, and the
  # body links to it under the page, so it has to travel in the archive.
  defp attachments(nil), do: []

  defp attachments(%Page{} = page) do
    from(a in Attachment,
      where: a.page_id == ^page.id,
      order_by: [asc: a.filename]
    )
    |> Repo.all()
  end

  # The page's own files, for the rail and the Markdown beside it: a reply's
  # screenshot is not an attachment of the page.
  defp own_files(files), do: Enum.reject(files, & &1.comment_id)

  defp comments(nil), do: []
  defp comments(%Page{} = page), do: Mirror.comments(page)

  defp excerpt(nil), do: ""
  defp excerpt(text), do: String.slice(to_string(text), 0, @description_chars)

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M") <> " UTC"
end
