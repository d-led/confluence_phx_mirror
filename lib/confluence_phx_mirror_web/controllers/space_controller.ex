defmodule ConfluencePhxMirrorWeb.SpaceController do
  @moduledoc """
  Confluence-style space browsing: the space overview.

  The space directory and the per-space catalogs (pages, blog, attachments) are
  `ConfluencePhxMirrorWeb.CatalogLive` because they are filtered and paged;
  what stays here is the overview and the redirect from a space link to the
  space home page, which is what readers expect from a space link.

  `/spaces/:key` redirects to the space home page when Confluence has one (that
  is what readers expect from a space link); the overview lives at
  `/spaces/:key/overview`, mirroring Confluence's own URL shape.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.NotFound

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

  defp render_overview(conn, space) do
    render(conn, :show,
      page_title: space.name,
      active: :overview,
      space: space,
      tree: Authorization.branch(scope(conn), space.id),
      home: Mirror.get_space_home(space),
      root_pages: Mirror.root_pages(space.id),
      recent_pages: Mirror.recent_pages_for_space(space, 6),
      posts: Mirror.blog_posts(space.id, 3),
      labels: Mirror.labels_in_space(space.id),
      attachment_count: Mirror.count_attachments_in_space(space.id)
    )
  end

  defp with_space(conn, key, fun) do
    case Mirror.find_space(key) do
      {:ok, space} ->
        if Authorization.can_read_space?(scope(conn), space) do
          fun.(conn, space)
        else
          NotFound.call(conn, "Space #{key} is not mirrored.")
        end

      {:error, :not_found} ->
        NotFound.call(conn, "Space #{key} is not mirrored.")
    end
  end

  defp scope(conn), do: Scope.from_assigns(conn.assigns)
end
