defmodule ConfluencePhxMirrorWeb.PeopleController do
  @moduledoc """
  One person's content, built from the bylines the sync recorded.

  Confluence keeps a separate user directory; the mirror deliberately does not
  invent accounts. The directory itself (`/people`) is a `CatalogLive`, because
  it is filtered and paged; this controller opens the pages one author wrote.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.NotFound

  @list_page 25

  def show(conn, %{"account_id" => account_id} = params) do
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
          pages: pages,
          offset: offset,
          more?: more?
        )
    end
  end

  defp offset(params) do
    case Integer.parse(to_string(params["offset"] || "0")) do
      {offset, ""} when offset > 0 -> offset
      _ -> 0
    end
  end
end
