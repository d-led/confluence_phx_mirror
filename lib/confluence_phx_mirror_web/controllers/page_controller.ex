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
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirrorWeb.NotFound
  alias ConfluencePhxMirrorWeb.Presence

  def home(conn, _params) do
    render(conn, :home,
      page_title: "Home",
      spaces: Mirror.spaces_with_counts(),
      recent_pages: visible(conn, Mirror.recent_pages(8)),
      labels: Mirror.list_labels(),
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
      canonical = URLs.page_path(page.space.key, page.confluence_id, page.slug)

      if slug == page.slug do
        render_page(conn, page)
      else
        redirect(conn, to: canonical)
      end
    else
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  def show(conn, %{"space_key" => space_key, "id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- readable?(conn, page) do
      redirect(conn, to: URLs.page_path(page.space.key, page.confluence_id, page.slug))
    else
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  def blog_post(conn, %{"key" => space_key, "id" => id, "slug" => slug}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- page.type == "blogpost",
         true <- readable?(conn, page) do
      if slug == page.slug do
        render_page(conn, page, :blog)
      else
        redirect(conn, to: URLs.blog_post_path(page.space.key, page.confluence_id, page.slug))
      end
    else
      _ -> NotFound.call(conn, "That blog post is not mirrored.")
    end
  end

  def recent(conn, _params) do
    pages = visible(conn, Mirror.list_all_pages())
    render(conn, :recent, page_title: "Recently updated", pages: pages)
  end

  def label(conn, %{"name" => name}) do
    pages = visible(conn, Mirror.pages_for_label(name))
    render(conn, :label, page_title: "Label: #{name}", label: name, pages: pages)
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
    space = page.space
    user = conn.assigns[:current_user]

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
      tree: Mirror.tree(space.id),
      breadcrumbs: breadcrumbs,
      children: Mirror.children(page),
      attachments: Mirror.attachments(page),
      comments: Mirror.comments(page),
      backlinks: Mirror.backlinks(page),
      outgoing_links: Mirror.outgoing_links(page),
      subscribed?: subscribed?(user, "page", page.id),
      space_subscribed?: subscribed?(user, "space", space.id),
      readers: Presence.count(page.confluence_id)
    )
  end

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

  defp subscribed?(%User{} = user, target_type, target_id) do
    Notifications.subscribed?(user, target_type, target_id)
  end

  defp subscribed?(_user, _target_type, _target_id), do: false

  defp scope(conn), do: Scope.for_user(conn.assigns[:current_user])

  defp readable?(conn, page), do: Authorization.can_read_page?(scope(conn), page)

  defp visible(conn, pages), do: Enum.filter(pages, &readable?(conn, &1))
end
