defmodule ConfluencePhxMirrorWeb.ExportController do
  @moduledoc """
  Downloads: one page as Markdown, a space as a streaming ZIP of Markdown, and
  a space as a standalone static site.

  Exports only read the mirror; nothing here writes content anywhere except the
  reader's browser.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.ArchiveDownload
  alias ConfluencePhxMirrorWeb.NotFound

  def space(conn, %{"key" => key}) do
    with {:ok, space} <- readable_space(conn, key) do
      ArchiveDownload.send(
        conn,
        Export.space_archive(space, scope(conn)),
        Export.archive_name(space)
      )
    end
  end

  @doc """
  The space as a static site: HTML pages, the same pages as Markdown, the
  space's attachments and the site's theme — every link already pointing at a
  file inside the archive.
  """
  def site(conn, %{"key" => key}) do
    with {:ok, space} <- readable_space(conn, key) do
      ArchiveDownload.send(
        conn,
        Export.space_site_archive(space, scope(conn)),
        Export.space_site_archive_name(space)
      )
    end
  end

  def page(conn, %{"space_key" => space_key, "id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- Authorization.can_read_page?(scope(conn), page) do
      conn
      |> put_resp_content_type("text/markdown; charset=utf-8")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{Export.page_filename(page)}")
      )
      |> send_resp(200, Export.page_markdown(page))
    else
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  # A space a reader may not see is not described anywhere — not on its page and
  # not in its export — so both answer "not mirrored".
  defp readable_space(conn, key) do
    with {:ok, space} <- Mirror.find_space(key),
         true <- Authorization.can_read_space?(scope(conn), space) do
      {:ok, space}
    else
      _ -> NotFound.call(conn, "Space #{key} is not mirrored.")
    end
  end

  defp scope(conn), do: Scope.from_assigns(conn.assigns)
end
