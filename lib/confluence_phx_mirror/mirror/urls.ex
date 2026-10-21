defmodule ConfluencePhxMirror.Mirror.URLs do
  @moduledoc """
  Canonical mirror URLs.

  Kept independent of `Phoenix` so that the sync pipeline (which has no
  connection) can build exactly the same links the web layer serves.
  """

  @doc "Pretty path of a mirrored page."
  def page_path(space_key, confluence_id, slug) do
    "/spaces/#{encode_segment(space_key)}/pages/#{confluence_id}/#{encode_segment(slug)}"
  end

  @doc "Path of a mirrored space."
  def space_path(space_key), do: "/spaces/#{encode_segment(space_key)}"

  @doc "Path of all pages carrying a label."
  def label_path(name), do: "/labels/#{encode_segment(name)}"

  @doc "Download path of a mirrored attachment."
  def attachment_path(space_key, page_confluence_id, attachment_confluence_id, filename) do
    "/attachments/#{encode_segment(space_key)}/#{page_confluence_id}/" <>
      "#{attachment_confluence_id}/#{encode_segment(filename)}"
  end

  defp encode_segment(segment), do: segment |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
