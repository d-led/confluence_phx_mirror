defmodule ConfluencePhxMirrorWeb.ExportController do
  @moduledoc """
  Downloads: one page as Markdown, one page with its files as a ZIP, a space as
  a streaming ZIP of Markdown, and a space as a standalone static site.

  Exports only read the mirror; nothing here writes content anywhere except the
  reader's browser. A copy leaving the building is a decision rather than a
  read, so every download is in the audit log before it starts — see
  `ConfluencePhxMirror.Export.audit_event_*_exported/2`.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.{Scope, User}
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.ArchiveDownload
  alias ConfluencePhxMirrorWeb.NotFound

  def space(conn, %{"key" => key}) do
    with {:ok, space} <- readable_space(conn, key) do
      audit(conn, Export.audit_event_space_exported(space, :markdown))

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
      audit(conn, Export.audit_event_space_exported(space, :static))

      ArchiveDownload.send(
        conn,
        Export.space_site_archive(space, scope(conn)),
        Export.space_site_archive_name(space)
      )
    end
  end

  def page(conn, %{"space_key" => space_key, "id" => id}) do
    with {:ok, page} <- readable_page(conn, space_key, id) do
      audit(conn, Export.audit_event_page_exported(page, :markdown))

      conn
      |> put_resp_content_type("text/markdown; charset=utf-8")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{Export.page_filename(page)}")
      )
      |> send_resp(200, Export.page_markdown(page))
    end
  end

  @doc """
  One page as a ZIP: the Markdown and, beside it, an `attachments/` folder with
  the files the page links to — what a Markdown viewer needs to render the page
  off a disk.
  """
  def page_archive(conn, %{"space_key" => space_key, "id" => id}) do
    with {:ok, page} <- readable_page(conn, space_key, id) do
      audit(conn, Export.audit_event_page_exported(page, :zip))

      ArchiveDownload.send(
        conn,
        Export.page_archive(page),
        Export.page_archive_name(page)
      )
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

  defp readable_page(conn, space_key, id) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id),
         true <- Authorization.can_read_page?(scope(conn), page) do
      {:ok, page}
    else
      _ -> NotFound.call(conn, "That page is not mirrored.")
    end
  end

  defp scope(conn), do: Scope.from_assigns(conn.assigns)

  # Who took the copy. The proxy in front of a deployment names every reader, so
  # an absent user means a request the deployment let through without one — and
  # the copy still happened, so it is still recorded, as the anonymous reader it
  # was.
  defp audit(conn, entry) do
    actor =
      case conn.assigns[:current_user] do
        %User{} = user -> {:user, user}
        _no_one -> {:system, "anonymous reader"}
      end

    Audit.log(actor, entry)
  end
end
