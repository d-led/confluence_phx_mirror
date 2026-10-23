defmodule ConfluencePhxMirrorWeb.PeopleController do
  @moduledoc """
  One person's content, built from the bylines the sync recorded.

  Confluence keeps a separate user directory; the mirror deliberately does not
  invent accounts. The directory itself (`/people`) is a `CatalogLive`, because
  it is filtered and paged; this controller opens the pages one author wrote.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.NotFound

  def show(conn, %{"account_id" => account_id}) do
    case Mirror.find_author(account_id) do
      nil ->
        NotFound.call(conn, "Nobody with that account wrote mirrored content.")

      author ->
        render(conn, :show,
          page_title: author.name,
          author: author,
          pages: readable_pages(conn, Mirror.pages_by_author(author.account_id))
        )
    end
  end

  # A byline lists what that person wrote *and* what the reader may open; a
  # restricted page stays with its author, not with every visitor.
  defp readable_pages(conn, pages) do
    Authorization.readable_pages(Scope.from_assigns(conn.assigns), pages)
  end
end
