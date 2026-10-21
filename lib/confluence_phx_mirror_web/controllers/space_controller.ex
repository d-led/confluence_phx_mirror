defmodule ConfluencePhxMirrorWeb.SpaceController do
  @moduledoc """
  Confluence-style space browsing: the space directory, the space overview and
  the per-space catalogs of pages, blog posts and attachments.

  `/spaces/:key` redirects to the space home page when Confluence has one (that
  is what readers expect from a space link); the overview lives at
  `/spaces/:key/overview`, mirroring Confluence's own URL shape.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.NotFound

  def index(conn, _params) do
    render(conn, :index, page_title: "Spaces", catalog: Mirror.space_catalog())
  end

  def show(conn, %{"key" => key}) do
    with_space(conn, key, fn conn, space ->
      case Mirror.get_space_home(space) do
        nil -> render_overview(conn, space)
        home -> redirect(conn, to: URLs.page_path(space.key, home.confluence_id, home.slug))
      end
    end)
  end

  def overview(conn, %{"key" => key}) do
    with_space(conn, key, &render_overview/2)
  end

  def pages(conn, %{"key" => key}) do
    with_space(conn, key, fn conn, space ->
      render(conn, :pages,
        page_title: "#{space.name} · Pages",
        active: :pages,
        space: space,
        tree: Mirror.tree(space.id),
        pages: Mirror.pages_in_space(space.id)
      )
    end)
  end

  def blog(conn, %{"key" => key}) do
    with_space(conn, key, fn conn, space ->
      render(conn, :blog,
        page_title: "#{space.name} · Blog",
        active: :blog,
        space: space,
        tree: Mirror.tree(space.id),
        posts: Mirror.blog_posts(space.id, 50)
      )
    end)
  end

  def attachments(conn, %{"key" => key}) do
    with_space(conn, key, fn conn, space ->
      render(conn, :attachments,
        page_title: "#{space.name} · Attachments",
        active: :attachments,
        space: space,
        tree: Mirror.tree(space.id),
        attachments: Mirror.attachments_in_space(space.id)
      )
    end)
  end

  defp render_overview(conn, space) do
    render(conn, :show,
      page_title: space.name,
      active: :overview,
      space: space,
      tree: Mirror.tree(space.id),
      home: Mirror.get_space_home(space),
      root_pages: Mirror.root_pages(space.id),
      recent_pages: Mirror.recent_pages_for_space(space, 6),
      posts: Mirror.blog_posts(space.id, 3),
      labels: Mirror.labels_in_space(space.id),
      attachment_count: length(Mirror.attachments_in_space(space.id))
    )
  end

  defp with_space(conn, key, fun) do
    case Mirror.find_space(key) do
      {:ok, space} -> fun.(conn, space)
      {:error, :not_found} -> NotFound.call(conn, "Space #{key} is not mirrored.")
    end
  end
end
