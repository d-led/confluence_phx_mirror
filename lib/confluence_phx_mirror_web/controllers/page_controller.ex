defmodule ConfluencePhxMirrorWeb.PageController do
  @moduledoc """
  Reader-facing pages: home, space, page, labels and about.

  Pages are ordinary controller actions (no LiveView) because they are
  read-only, cacheable and must work without JavaScript.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirrorWeb.Presence

  def home(conn, _params) do
    render(conn, :home,
      page_title: "Home",
      spaces: Mirror.spaces_with_counts(),
      recent_pages: Mirror.recent_pages(8),
      labels: Mirror.list_labels(),
      stats: Mirror.stats(),
      last_webhook: List.first(Webhooks.recent(1))
    )
  end

  def space(conn, %{"key" => key}) do
    case Mirror.find_space(key) do
      {:ok, space} ->
        case Mirror.get_space_home(space) do
          nil -> render_space(conn, space)
          home -> redirect(conn, to: URLs.page_path(space.key, home.confluence_id, home.slug))
        end

      {:error, :not_found} ->
        not_found(conn, "Space #{key} is not mirrored.")
    end
  end

  def show(conn, %{"space_key" => space_key, "id" => id, "slug" => slug}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id) do
      canonical = URLs.page_path(page.space.key, page.confluence_id, page.slug)

      if slug == page.slug do
        render_page(conn, page)
      else
        redirect(conn, to: canonical)
      end
    else
      _ -> not_found(conn, "That page is not mirrored.")
    end
  end

  def show(conn, %{"space_key" => space_key, "id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id) do
      redirect(conn, to: URLs.page_path(page.space.key, page.confluence_id, page.slug))
    else
      _ -> not_found(conn, "That page is not mirrored.")
    end
  end

  def labels(conn, _params) do
    render(conn, :labels, page_title: "Labels", labels: Mirror.list_labels())
  end

  def label(conn, %{"name" => name}) do
    pages = Mirror.pages_for_label(name)
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

  defp render_page(conn, page) do
    space = page.space
    user = conn.assigns[:current_user]

    breadcrumbs =
      [%{title: space.name, path: URLs.space_path(space.key)}] ++
        Enum.map(Mirror.ancestor_pages(page), fn ancestor ->
          %{
            title: ancestor.title,
            path: URLs.page_path(ancestor.space.key, ancestor.confluence_id, ancestor.slug)
          }
        end)

    render(conn, :show,
      page_title: page.title,
      page: page,
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

  defp render_space(conn, space) do
    render(conn, :space,
      page_title: space.name,
      space: space,
      tree: Mirror.tree(space.id),
      root_pages: Mirror.root_pages(space.id),
      recent_pages: Mirror.recent_pages_for_space(space, 6),
      breadcrumbs: [%{title: space.name, path: URLs.space_path(space.key)}]
    )
  end

  defp subscribed?(%User{} = user, target_type, target_id) do
    Notifications.subscribed?(user, target_type, target_id)
  end

  defp subscribed?(_user, _target_type, _target_id), do: false

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> put_view(ConfluencePhxMirrorWeb.ErrorHTML)
    |> render(:"404", message: message)
  end
end
