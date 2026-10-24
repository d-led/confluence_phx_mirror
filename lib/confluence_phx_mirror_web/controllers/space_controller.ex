defmodule ConfluencePhxMirrorWeb.SpaceController do
  @moduledoc """
  Confluence-style space browsing: the space overview.

  The space directory and the per-space catalogs (pages, blog, attachments) are
  `ConfluencePhxMirrorWeb.CatalogLive` because they are filtered and paged;
  what stays here is the overview, the space icon and the redirect from a space
  link to the space home page, which is what readers expect from a space link.

  `/spaces/:key` redirects to the space home page when Confluence has one (that
  is what readers expect from a space link); the overview lives at
  `/spaces/:key/overview`, mirroring Confluence's own URL shape.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Blobs.LocalStore
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.NotFound

  # The overview is a front page, not the catalog: it shows a window of each
  # list and links to the screen that pages through the rest.
  @root_page_cards 6
  @label_chips 12

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

  @doc """
  One sidebar node's children, as the `<li>`s the tree draws.

  The sidebar is collapsed except for the trail to the page being read, so this
  is how a branch opens: one request per branch a reader actually expands, and
  never the whole space. Rows the reader may not open are not in the answer.
  """
  def tree(conn, %{"key" => key, "page_id" => page_id}) do
    with_space(conn, key, fn conn, space ->
      with {id, ""} <- Integer.parse(page_id),
           {:ok, page} <- Mirror.find_page_by_local_id(id),
           true <- page.space_id == space.id do
        nodes =
          space.id
          |> Mirror.tree_children(page, filter: &Authorization.restrict_pages(&1, scope(conn)))
          |> Enum.map(&%{page: &1, children: []})

        conn
        |> put_root_layout(false)
        |> put_resp_content_type("text/html")
        |> render(:tree, nodes: nodes, space_key: space.key, layout: false)
      else
        _not_here -> NotFound.call(conn, "No such page in #{space.key}.")
      end
    end)
  end

  @doc """
  Serves the space icon from the blob store.

  The icon says which space a row is about, so it is content: a reader who may
  not read the space does not get its picture either. Both answers are the same
  404 — an image is not a page, and a picture would tell a reader the space
  exists.
  """
  # The path comes from Blobs.Store, whose keys are sanitised segments under the
  # blob root; space_controller_test covers the traversal attempt.
  # sobelow_skip ["Traversal.SendFile"]
  def icon(conn, %{"key" => key}) do
    with {:ok, space} <- readable_space(conn, key),
         {:ok, path} <- icon_path(space) do
      conn
      |> put_resp_header("content-type", space.icon_media_type || "application/octet-stream")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'")
      |> put_space_etag(space)
      |> send_file(200, path)
    else
      _missing ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "This space has no icon.")
    end
  end

  defp readable_space(conn, key) do
    with {:ok, space} <- Mirror.find_space(key),
         true <- Authorization.can_read_space?(scope(conn), space) do
      {:ok, space}
    end
  end

  defp icon_path(%{icon_blob_key: nil}), do: {:error, :no_icon}

  defp icon_path(%{icon_blob_key: blob_key}) do
    path = LocalStore.absolute_path(blob_key)
    if File.regular?(path), do: {:ok, path}, else: {:error, :missing_blob}
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  defp put_space_etag(conn, %{icon_sha256: sha}) when is_binary(sha) do
    put_resp_header(conn, "etag", ~s("#{sha}"))
  end

  defp put_space_etag(conn, _space), do: conn

  defp render_overview(conn, space) do
    render(conn, :show,
      page_title: space.name,
      active: :overview,
      space: space,
      tree: Authorization.branch(scope(conn), space.id),
      home: Mirror.get_space_home(space),
      root_pages: Mirror.root_pages(space.id, limit: @root_page_cards),
      recent_pages: Mirror.recent_pages_for_space(space, 6),
      posts: Mirror.blog_posts(space.id, 3),
      labels: Mirror.labels_in_space(space.id, limit: @label_chips, order: :popular),
      attachment_count: Mirror.count_attachments_in_space(space.id),
      grants: space_grants(conn, space)
    )
  end

  # Who may read a space is administrative information: the sync mirrors it from
  # Confluence, and an administrator is the one who needs to see whether the
  # mirror agrees with the site.
  defp space_grants(conn, space) do
    if Scope.admin?(scope(conn)), do: Mirror.space_grants(space.id)
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
