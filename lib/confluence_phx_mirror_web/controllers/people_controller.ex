defmodule ConfluencePhxMirrorWeb.PeopleController do
  @moduledoc """
  One person's content, built from the bylines the sync recorded.

  Confluence keeps a separate user directory; the mirror deliberately does not
  invent accounts. The directory itself (`/people`) is a `CatalogLive`, because
  it is filtered and paged; this controller opens the pages one author wrote.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Blobs.LocalStore
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirrorWeb.NotFound

  @list_page 25

  def show(conn, %{"account_id" => account_id} = params) do
    if Publishing.anonymise_contributors?() do
      # The page is a byline with the mirror's content attached to it, so a
      # deployment that publishes no names publishes none of these either.
      NotFound.call(conn, "This mirror does not publish its contributors.")
    else
      render_author(conn, account_id, params)
    end
  end

  defp render_author(conn, account_id, params) do
    case Mirror.find_author(account_id) do
      nil ->
        NotFound.call(conn, "Nobody with that account wrote mirrored content.")

      author ->
        offset = offset(params)

        # A byline lists what that person wrote *and* what the reader may open;
        # the restriction is part of the query, so the page asks for one window
        # of rows rather than every page the person ever touched.
        %{items: pages, more?: more?} =
          Catalog.pages_by_author(Scope.from_assigns(conn.assigns), author.account_id,
            limit: @list_page,
            offset: offset
          )

        render(conn, :show,
          page_title: author.name,
          author: author,
          person: Mirror.find_person(author.account_id),
          pages: pages,
          offset: offset,
          more?: more?
        )
    end
  end

  @doc """
  The picture the site publishes for this person.

  A face is the site's content like an attachment, so it lives in the blob store
  and is served from here — the mirror never sends a reader to the site for it.

  A deployment that publishes no names publishes no faces either: the same 404
  its person page answers with.
  """
  # The key comes from `Blobs.Key`, whose segments are sanitised; nothing in the
  # path reaches the file system unescaped.
  # sobelow_skip ["Traversal.SendFile"]
  def avatar(conn, %{"account_id" => account_id}) do
    person = unless Publishing.anonymise_contributors?(), do: Mirror.find_person(account_id)
    path = person && person.avatar_blob_key && LocalStore.absolute_path(person.avatar_blob_key)

    if path && File.regular?(path) do
      conn
      |> put_resp_header("content-type", person.avatar_media_type || "application/octet-stream")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "This mirror has no picture of that person.")
    end
  end

  defp offset(params) do
    case Integer.parse(to_string(params["offset"] || "0")) do
      {offset, ""} when offset > 0 -> offset
      _ -> 0
    end
  end
end
