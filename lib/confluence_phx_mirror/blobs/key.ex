defmodule ConfluencePhxMirror.Blobs.Key do
  @moduledoc """
  Builds blob keys from Confluence identities.

  Keys are stable, readable and safe: they never contain user input that can
  escape the store root, and they keep the file extension so that tooling can
  open the files directly.
  """

  @max_filename_bytes 120

  @doc """
  Key for a page attachment:

      spaces/ENG/pages/12345/attachments/67890/architecture-diagram.svg
  """
  def attachment(space_key, page_confluence_id, attachment_confluence_id, filename) do
    Path.join([
      "spaces",
      sanitise_segment(space_key, "SPACE"),
      "pages",
      sanitise_segment(page_confluence_id, "page"),
      "attachments",
      sanitise_segment(attachment_confluence_id, "attachment"),
      sanitise_filename(filename)
    ])
  end

  @doc """
  Key for a space icon:

      spaces/ENG/icon.png

  Confluence's icon paths carry no file extension, so the extension comes from
  the media type the site answered with. One icon per space: a new upload
  replaces the bytes under the same key.
  """
  def space_icon(space_key, media_type) do
    Path.join([
      "spaces",
      sanitise_segment(space_key, "SPACE"),
      "icon" <> icon_extension(media_type)
    ])
  end

  defp icon_extension(media_type) do
    case media_type |> to_string() |> String.split(";") |> hd() |> String.trim() do
      "image/png" -> ".png"
      "image/jpeg" -> ".jpg"
      "image/gif" -> ".gif"
      "image/webp" -> ".webp"
      "image/svg+xml" -> ".svg"
      _ -> ".bin"
    end
  end

  @doc """
  Makes a filename safe for a blob key while keeping it recognisable.

  `../etc/passwd` becomes `etc-passwd`; the original filename stays in the
  database and is what the download route serves with `Content-Disposition`.
  """
  def sanitise_filename(nil), do: "attachment"

  def sanitise_filename(filename) do
    filename = to_string(filename)

    basename =
      filename
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]+/u, "-")
      |> String.trim("-")
      |> String.trim(".")

    {stem, extension} = split_extension(basename)

    stem =
      stem
      |> String.slice(0, max(@max_filename_bytes - byte_size(extension), 1))
      |> String.trim("-")
      |> case do
        "" -> "attachment"
        safe -> safe
      end

    stem <> extension
  end

  defp split_extension(basename) do
    extension = Path.extname(basename)

    if byte_size(extension) in 2..12 do
      {Path.rootname(basename), String.replace(extension, ~r/[^A-Za-z0-9.]/u, "")}
    else
      {basename, ""}
    end
  end

  defp sanitise_segment(value, fallback) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_~.-]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> fallback
      segment -> segment
    end
  end
end
