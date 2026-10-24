defmodule ConfluencePhxMirrorWeb.PageController do
  @moduledoc """
  Reader-facing pages: home, space, page, labels and about.

  Pages are ordinary controller actions (no LiveView) because they are
  read-only, cacheable and must work without JavaScript.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Sync.PageWorker
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirrorWeb.NotFound

  # The directory is `/spaces`, which pages in the database. The home page shows
  # a window of it: a mirror with a thousand spaces would otherwise send a
  # thousand cards with every visit.
  @space_cards 12
  @label_cards 14
  @list_page 25
  # The home page shows a window of what changed, not the feed: "see all" is
  # one click away, and the query behind the window is the same paged one.
  @recent_changes 8

  def home(conn, _params) do
    spaces = readable_spaces(conn)
    %{items: changes} = Catalog.recent(scope(conn), limit: @recent_changes)

    render(conn, :home,
      page_title: "Home",
      spaces: Enum.take(spaces, @space_cards),
      space_total: length(spaces),
      recent_pages: changes,
      labels: Catalog.label_counts(scope(conn), limit: @label_cards),
      stats: Mirror.stats(),
      last_webhook: List.first(Webhooks.recent(1))
    )
  end

  def space(conn, %{"key" => key}) do
    case Mirror.find_space(key) do
      {:ok, space} ->
        if Authorization.can_read_space?(scope(conn), space) do
          redirect_to_space_home(conn, space)
        else
          NotFound.call(conn, "Space #{key} is not mirrored.")
        end

      {:error, :not_found} ->
        NotFound.call(conn, "Space #{key} is not mirrored.")
    end
  end

  defp redirect_to_space_home(conn, space) do
    case Mirror.get_space_home(space) do
      nil -> redirect(conn, to: URLs.space_overview_path(space.key))
      home -> redirect(conn, to: URLs.page_path(space.key, home.confluence_id, home.slug))
    end
  end

  def show(conn, %{"space_key" => space_key, "id" => id, "slug" => slug}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- readable?(conn, page) do
      if Page.slug_match?(page, slug) do
        render_page(conn, page)
      else
        redirect(conn, to: URLs.page_path(page.space.key, page.confluence_id, page.slug))
      end
    else
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  # A page whose title has nothing slug-worthy — a Cyrillic or CJK title — is
  # served by id alone, exactly as Confluence serves it. It must render here
  # rather than redirect to itself.
  def show(conn, %{"space_key" => space_key, "id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- readable?(conn, page) do
      if Page.slug_match?(page, "") do
        render_page(conn, page)
      else
        redirect(conn, to: URLs.page_path(page.space.key, page.confluence_id, page.slug))
      end
    else
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  @doc """
  Re-reads one mirrored page from Confluence, on an administrator's request.

  Everything that hangs off a page — its attachments, its comments, its labels
  and its permissions — is fetched while the page itself is read, so one page
  sync refreshes all of it. The read happens in the background: the reader gets
  the page back immediately and the sync queue reports the outcome.
  """
  def resync(conn, %{"space_key" => space_key, "id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- may_resync?(conn, page) do
      enqueue_resync(conn, page)
    else
      # A reader who may not resync learns nothing a stranger would not: the
      # answer is the one an unknown page gets.
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  defp may_resync?(conn, page) do
    Scope.admin?(scope(conn)) and readable?(conn, page)
  end

  defp enqueue_resync(conn, page) do
    %{
      "confluence_id" => page.confluence_id,
      "trigger" => "the page view, by #{conn.assigns[:current_user].email}"
    }
    |> PageWorker.new()
    |> Oban.insert()

    conn
    |> put_flash(:info, "Re-reading “#{page.title}”, its attachments and its comments.")
    |> redirect(to: URLs.content_path(page.space.key, page))
  end

  def blog_post(conn, %{"key" => space_key, "id" => id} = params) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- page.type == "blogpost",
         true <- readable?(conn, page) do
      open_blog_post(conn, page, params["slug"] || "")
    else
      _ -> NotFound.call(conn, "That blog post is not mirrored.")
    end
  end

  # The address is the post's own slug; anything else forwards to it, so a
  # renamed post keeps one URL and every older link still lands.
  defp open_blog_post(conn, page, slug) do
    if Page.slug_match?(page, slug) do
      render_page(conn, page, :blog)
    else
      redirect(conn, to: URLs.blog_post_path(page.space.key, page.confluence_id, page.slug))
    end
  end

  # The list queries are paged in the database: the mirror answers "the next
  # twenty-five" instead of loading every page and slicing the list in memory.
  def recent(conn, params) do
    offset = offset(params)
    %{items: pages, more?: more?} = Catalog.recent(scope(conn), limit: @list_page, offset: offset)

    render(conn, :recent,
      page_title: "Recently updated",
      pages: pages,
      offset: offset,
      more?: more?
    )
  end

  def label(conn, %{"name" => name} = params) do
    offset = offset(params)

    %{items: pages, more?: more?} =
      Catalog.pages_with_label(scope(conn), name, limit: @list_page, offset: offset)

    render(conn, :label,
      page_title: "Label: #{name}",
      label: name,
      pages: pages,
      offset: offset,
      more?: more?
    )
  end

  def about(conn, _params) do
    render(conn, :about,
      page_title: "About",
      stats: Mirror.stats(),
      webhook_secret_configured:
        is_binary(Application.get_env(:confluence_phx_mirror, :webhooks, [])[:secret])
    )
  end

  # The page body is Confluence's export_view after Sync.Renderer sanitised it
  # (scripts, event handlers and javascript: URLs removed) when the page was
  # mirrored; rendering it raw is the whole point of the mirror.
  # sobelow_skip ["XSS.Raw"]
  defp render_page(conn, page, kind \\ :page) do
    etag = page_etag(conn, page, kind)
    conn = conn |> put_reader_cache(etag)

    if requested_etag?(conn, etag) do
      send_resp(conn, 304, "")
    else
      do_render_page(conn, page, kind)
    end
  end

  # A mirrored page only changes when the sync rewrites it, so a reader who
  # already has it can be answered with an empty 304 instead of a re-render.
  # A page carries an administrator-only action and a tree of only the pages
  # this reader may open, so the tag names the viewer as well as the version: a
  # cached copy is only ever offered back to the viewer it was rendered for.
  defp page_etag(conn, page, kind) do
    viewer = if Scope.admin?(scope(conn)), do: "admin", else: "reader"

    ~s("#{page.confluence_id}-#{page.version_number}-#{kind}-#{viewer}-#{DateTime.to_unix(page.updated_at)}")
  end

  defp put_reader_cache(conn, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "public, max-age=0, must-revalidate")
  end

  defp requested_etag?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  # `page.body_export` is rendered raw on purpose — see `render_page/3`: Sync
  # sanitised it when the page was mirrored, and re-rendering it is the mirror's
  # whole job. sobelow cannot see across the function boundary.
  # sobelow_skip ["XSS.Raw"]
  defp do_render_page(conn, page, kind) do
    :telemetry.execute([:confluence_mirror, :page, :view], %{count: 1}, %{kind: kind})

    space = page.space
    user = conn.assigns[:current_user]
    watching = watched(user, [{"page", page.id}, {"space", space.id}])

    breadcrumbs =
      case kind do
        :page -> page |> Mirror.breadcrumbs() |> crumb_paths(space)
        :blog -> [space_crumb(space), %{title: "Blog", path: URLs.space_blog_path(space.key)}]
      end

    render(conn, :show,
      page_title: page.title,
      page: page,
      kind: kind,
      space: space,
      tree: tree_for(scope(conn), space, page, kind),
      breadcrumbs: breadcrumbs,
      children: children_window(scope(conn), page),
      child_count: Mirror.count_children(page),
      attachments: Mirror.attachments(page),
      comments: Mirror.comments(page),
      backlinks: Mirror.backlinks(page),
      outgoing_links: Mirror.outgoing_links(page),
      subscribed?: MapSet.member?(watching, {"page", page.id}),
      space_subscribed?: MapSet.member?(watching, {"space", space.id}),
      admin?: Scope.admin?(scope(conn)),
      resync_path: URLs.page_resync_path(space.key, page.confluence_id)
    )
  end

  # A front page in a big space has hundreds of children, and a page that lists
  # them all is a page nobody scrolls: the view shows a window, the count says
  # how much is behind it, and the space's catalog pages through the rest.
  @child_window 10

  defp children_window(scope, page) do
    pages = Mirror.children(page, limit: @child_window)
    Authorization.readable_pages(scope, pages)
  end

  # The sidebar follows the reader: the trail to this page, its siblings and its
  # children, and nothing a reader may not open. A blog post is not part of the
  # page tree, so its view gets the space's roots instead.
  defp tree_for(scope, space, _page, :blog), do: Authorization.branch(scope, space.id)
  defp tree_for(scope, space, page, :page), do: Authorization.branch(scope, space.id, page)

  # A crumb keeps the identity it was built with — the space's home page id, a
  # page's Confluence id — because the breadcrumb component needs it to avoid
  # naming the same page twice; a path is all the template needs to link it.
  defp crumb_paths(crumbs, space), do: Enum.map(crumbs, &crumb_path(&1, space))

  defp crumb_path(%{kind: :space} = crumb, space),
    do: Map.put(crumb, :path, URLs.space_path(space.key))

  defp crumb_path(%{kind: :page} = crumb, space),
    do: Map.put(crumb, :path, URLs.page_path(space.key, crumb.confluence_id, crumb.slug))

  defp space_crumb(space) do
    %{
      title: space.name,
      path: URLs.space_path(space.key),
      homepage_confluence_id: space.homepage_confluence_id
    }
  end

  defp watched(%User{} = user, targets), do: Notifications.watching(user, targets)
  defp watched(_user, _targets), do: MapSet.new()

  defp scope(conn), do: Scope.from_assigns(conn.assigns)

  defp readable?(conn, page), do: Authorization.can_read_page?(scope(conn), page)

  # The home rail is the same list as the space switcher, so it asks the same
  # question; a space the reader may not open is not advertised here either.
  defp readable_spaces(conn) do
    allowed = conn |> scope() |> Authorization.readable_spaces() |> MapSet.new(& &1.id)

    Enum.filter(Mirror.spaces_with_counts(), fn {space, _count} ->
      MapSet.member?(allowed, space.id)
    end)
  end

  defp offset(params) do
    case Integer.parse(to_string(params["offset"] || "0")) do
      {offset, ""} when offset > 0 -> offset
      _ -> 0
    end
  end
end
