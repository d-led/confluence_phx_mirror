defmodule ConfluencePhxMirrorWeb.ExportController do
  @moduledoc """
  Downloads: one page as Markdown, one space as a streaming ZIP with Markdown
  and attachments.

  Exports only read the mirror; nothing here writes content anywhere except the
  reader's browser.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.Zip
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.NotFound

  def space(conn, %{"key" => key}) do
    case Mirror.find_space(key) do
      {:ok, space} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{Export.archive_name(space)}")
        )
        |> send_chunked(200)
        |> stream_zip(Export.space_archive(space))

      {:error, :not_found} ->
        NotFound.call(conn, "Space #{key} is not mirrored.")
    end
  end

  def page(conn, %{"space_key" => space_key, "id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, page} <- Mirror.find_page_by_path(space_key, id) do
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

  defp stream_zip(conn, entries) do
    entries
    |> Zip.chunks()
    |> Enum.reduce_while(conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, IO.iodata_to_binary(chunk)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end
end
