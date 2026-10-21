defmodule ConfluencePhxMirrorWeb.PeopleController do
  @moduledoc """
  The people directory, built from the bylines the sync recorded.

  Confluence keeps a separate user directory; the mirror deliberately does not
  invent accounts. It lists exactly the authors that appear on mirrored
  content, which is enough to browse "who wrote what" offline.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.NotFound

  def index(conn, _params) do
    render(conn, :index, page_title: "People", authors: Mirror.authors())
  end

  def show(conn, %{"account_id" => account_id}) do
    case Mirror.find_author(account_id) do
      nil ->
        NotFound.call(conn, "Nobody with that account wrote mirrored content.")

      author ->
        render(conn, :show,
          page_title: author.name,
          author: author,
          pages: Mirror.pages_by_author(author.account_id)
        )
    end
  end
end
