defmodule ConfluencePhxMirrorWeb.AttachmentController do
  @moduledoc """
  Serves attachment bytes from the blob store.

  Files are addressed by space, page, attachment id and filename, which makes
  URLs readable and stable. The database row is the source of truth for
  media type and hash; a missing file is a 404, never a directory listing.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Blobs.LocalStore
  alias ConfluencePhxMirror.Mirror

  # The path comes from Blobs.Store, whose keys are sanitised segments under
  # the blob root; attachment_controller_test covers the traversal attempt.
  # sobelow_skip ["Traversal.SendFile"]
  def show(
        conn,
        %{
          "space_key" => space_key,
          "page_id" => page_id,
          "attachment_id" => attachment_id,
          "filename" => filename
        } = params
      ) do
    with {page_id, ""} <- Integer.parse(page_id),
         {attachment_id, ""} <- Integer.parse(attachment_id),
         :ok <- authorize(conn, space_key, page_id),
         {:ok, attachment} <- fetch_attachment(space_key, page_id, attachment_id, filename),
         {:ok, path} <- blob_path(attachment) do
      conn
      |> put_resp_header("content-type", attachment.media_type || "application/octet-stream")
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> maybe_etag(attachment)
      |> put_resp_header("content-disposition", disposition(attachment, params))
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Attachment not found")
    end
  end

  defp fetch_attachment(space_key, page_id, attachment_id, filename) do
    {:ok, Mirror.get_attachment!(space_key, page_id, attachment_id, filename)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # Attachment bytes are content: the page decides, exactly like the page view.
  defp authorize(conn, space_key, page_id) do
    scope = Scope.for_user(conn.assigns[:current_user])

    with {:ok, space} <- Mirror.find_space(space_key),
         true <- Authorization.can_read_space?(scope, space),
         {:ok, page} <- Mirror.find_page_by_path(space_key, page_id),
         true <- Authorization.can_read_page?(scope, page) do
      :ok
    else
      _ -> :error
    end
  end

  defp blob_path(%{blob_key: nil}), do: {:error, :missing_blob}

  defp blob_path(%{blob_key: blob_key}) do
    path = LocalStore.absolute_path(blob_key)
    if File.regular?(path), do: {:ok, path}, else: {:error, :missing_blob}
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  defp maybe_etag(conn, %{sha256: sha}) when is_binary(sha) do
    put_resp_header(conn, "etag", ~s("#{sha}"))
  end

  defp maybe_etag(conn, _attachment), do: conn

  defp disposition(attachment, params) do
    type =
      if params["download"] == "1" or not inline?(attachment.media_type) do
        "attachment"
      else
        "inline"
      end

    ~s(#{type}; filename="#{escape_filename(attachment.filename)}")
  end

  defp inline?(media_type) do
    String.starts_with?(media_type || "", "image/") or media_type == "application/pdf" or
      String.starts_with?(media_type || "", "text/")
  end

  defp escape_filename(filename) do
    filename
    |> to_string()
    |> String.replace(~r/["\\\r\n]/, "_")
  end
end
